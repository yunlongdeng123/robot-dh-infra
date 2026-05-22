#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
ENV_FILE="$PROJECT_DIR/.env"
DATA_ROOT="/data/robot-dh/datasets"
RAW_ROOT="$DATA_ROOT/raw"
MANIFEST_ROOT="$DATA_ROOT/manifests"
BRIDGE_SOURCE_PATH="${BRIDGE_SOURCE_PATH:-/README.md}"
BRIDGE_HF_REPO="${BRIDGE_HF_REPO:-mbodiai/oxe_bridge_v2}"
BRIDGE_HF_FILE="${BRIDGE_HF_FILE:-data/shard_0-00000-of-00001.parquet}"
STATUS=0
RUN_DROID_CALIBRATION=1
RUN_DROID_LEROBOT=1
RUN_BRIDGE=1
RUN_ROBOMIMIC=1
HF_SOURCE_ENDPOINT="https://huggingface.co"
HF_SOURCE_LABEL="official"

usage() {
  cat <<EOF >&2
Usage: $0 [--bridge-source-path PATH] [--only DATASET]

Datasets for --only:
  droid-calibration
  droid-lerobot
  bridgedata-v2
  robomimic
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bridge-source-path)
      shift
      if [[ $# -eq 0 ]]; then
        usage
        exit 1
      fi
      BRIDGE_SOURCE_PATH="$1"
      ;;
    --only)
      shift
      if [[ $# -eq 0 ]]; then
        usage
        exit 1
      fi
      RUN_DROID_CALIBRATION=0
      RUN_DROID_LEROBOT=0
      RUN_BRIDGE=0
      RUN_ROBOMIMIC=0
      case "$1" in
        droid-calibration)
          RUN_DROID_CALIBRATION=1
          ;;
        droid-lerobot)
          RUN_DROID_LEROBOT=1
          ;;
        bridgedata-v2)
          RUN_BRIDGE=1
          ;;
        robomimic)
          RUN_ROBOMIMIC=1
          ;;
        *)
          usage
          exit 1
          ;;
      esac
      ;;
    *)
      usage
      exit 1
      ;;
  esac
  shift
done

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE not found. Run ./scripts/03_generate_env.sh first." >&2
  exit 1
fi

as_root() {
  if [[ ${EUID} -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

for required_cmd in python3 mc sha256sum find sort; do
  if ! command -v "$required_cmd" >/dev/null 2>&1; then
    echo "ERROR: Missing required command: $required_cmd" >&2
    exit 1
  fi
done

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

export HF_HOME="${HF_HOME:-/data/robot-dh/cache/huggingface}"
unset HF_HUB_ENABLE_HF_TRANSFER
export HF_XET_HIGH_PERFORMANCE="${HF_XET_HIGH_PERFORMANCE:-1}"
export OPENXLAB_CACHE_DIR="${OPENXLAB_CACHE_DIR:-/data/robot-dh/cache/openxlab}"

mkdir -p \
  "$RAW_ROOT/droid/calibration" \
  "$RAW_ROOT/droid/lerobot_sample" \
  "$RAW_ROOT/bridgedata_v2/sample" \
  "$RAW_ROOT/robomimic/sample" \
  "$MANIFEST_ROOT"

ensure_writable_dataset_dirs() {
  if [[ -w "$DATA_ROOT" && -w "$MANIFEST_ROOT" && -w "$RAW_ROOT" ]]; then
    return 0
  fi

  as_root chown -R "$(id -u):$(id -g)" "$DATA_ROOT" /data/robot-dh/cache
}

configure_hf_endpoint() {
  if curl -4fsS --max-time 15 -o /dev/null https://huggingface.co; then
    unset HF_ENDPOINT
    HF_SOURCE_ENDPOINT="https://huggingface.co"
    HF_SOURCE_LABEL="official"
    return 0
  fi

  if curl -fsS --max-time 15 -o /dev/null https://hf-mirror.com; then
    export HF_ENDPOINT="https://hf-mirror.com"
    HF_SOURCE_ENDPOINT="$HF_ENDPOINT"
    HF_SOURCE_LABEL="mirror"
    return 0
  fi

  echo "ERROR: Neither huggingface.co nor hf-mirror.com is reachable from this host." >&2
  return 1
}

setup_mc_alias() {
  mc alias set rdh http://127.0.0.1:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null
  mc mb --ignore-existing "rdh/$ROBOT_DH_DATA_BUCKET" >/dev/null
}

resolve_openxlab_cli() {
  if command -v openxlab >/dev/null 2>&1; then
    command -v openxlab
    return 0
  fi

  if [[ -x "$HOME/.local/bin/openxlab" ]]; then
    printf '%s\n' "$HOME/.local/bin/openxlab"
    return 0
  fi

  return 1
}

openxlab_cli() {
  "$OPENXLAB_BIN" "$@"
}

OPENXLAB_BIN=""
if [[ $RUN_BRIDGE -eq 1 ]]; then
  if ! OPENXLAB_BIN=$(resolve_openxlab_cli); then
    OPENXLAB_BIN=""
  fi
fi

download_hf_exact_files() {
  local repo_id="$1"
  local target_dir="$2"
  shift 2

  python3 - "$repo_id" "$target_dir" "$@" <<'PY'
from huggingface_hub import hf_hub_download
import sys

repo_id = sys.argv[1]
local_dir = sys.argv[2]
files = sys.argv[3:]

if not files:
    raise RuntimeError(f"No files requested for {repo_id}")

for filename in files:
    hf_hub_download(
        repo_id=repo_id,
        repo_type="dataset",
        filename=filename,
        local_dir=local_dir,
    )
PY
}

write_file_manifests() {
  local source_dir="$1"
  local prefix="$2"
  local files_manifest="$MANIFEST_ROOT/${prefix}_files.tsv"
  local sha_manifest="$MANIFEST_ROOT/${prefix}_sha256.txt"

  if ! find "$source_dir" -type f -print -quit | grep -q .; then
    echo "ERROR: No files were downloaded under $source_dir" >&2
    return 1
  fi

  (
    cd "$source_dir"
    find . -type f -printf '%P\t%s\n' | LC_ALL=C sort > "$files_manifest"
    find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum > "$sha_manifest"
  )
}

write_hf_source_manifest() {
  local prefix="$1"
  local repo_id="$2"

  python3 - <<PY > "$MANIFEST_ROOT/${prefix}_source.json"
from datetime import datetime, timezone
import json
from huggingface_hub import HfApi

repo_id = ${repo_id@Q}
info = HfApi().dataset_info(repo_id)

print(json.dumps({
    "source_repo": repo_id,
    "source_revision": info.sha,
    "download_tool": "huggingface_hub.snapshot_download",
  "download_endpoint": ${HF_SOURCE_ENDPOINT@Q},
  "download_endpoint_mode": ${HF_SOURCE_LABEL@Q},
    "download_time_utc": datetime.now(timezone.utc).isoformat(),
}, ensure_ascii=False, indent=2))
PY
}

write_bridge_source_manifest() {
  python3 - <<PY > "$MANIFEST_ROOT/bridgedata_v2_sample_source.json"
from datetime import datetime, timezone
import json

print(json.dumps({
    "source_repo": ${BRIDGE_HF_REPO@Q},
    "source_path": ${BRIDGE_HF_FILE@Q},
    "download_tool": "huggingface_hub.hf_hub_download",
    "download_endpoint": ${HF_SOURCE_ENDPOINT@Q},
    "download_endpoint_mode": ${HF_SOURCE_LABEL@Q},
    "download_time_utc": datetime.now(timezone.utc).isoformat(),
}, ensure_ascii=False, indent=2))
PY
}

mirror_dataset() {
  local source_dir="$1"
  local dest_prefix="$2"
  mc mirror --overwrite "$source_dir" "rdh/$ROBOT_DH_DATA_BUCKET/$dest_prefix"
}

mirror_manifest() {
  local file_path="$1"
  local dest_name="$2"
  mc cp "$file_path" "rdh/$ROBOT_DH_DATA_BUCKET/manifests/$dest_name"
}

download_droid_calibration() {
  local target_dir="$RAW_ROOT/droid/calibration"

  python3 - <<'PY'
from huggingface_hub import snapshot_download

snapshot_download(
    repo_id="KarlP/droid",
    repo_type="dataset",
    local_dir="/data/robot-dh/datasets/raw/droid/calibration",
    allow_patterns=[
        "*.json",
        "*.md",
        "**/*.json",
        "**/*.md",
    ],
)
PY

  if ! find "$target_dir" -type f \( -name '*.json' -o -name '*.jsonl' \) -print -quit | grep -q .; then
    echo "ERROR: The reachable KarlP/droid source does not expose calibration JSON payloads; only README/cache artifacts were fetched." >&2
    return 1
  fi

  write_hf_source_manifest droid_calibration KarlP/droid || return 1
  write_file_manifests "$target_dir" droid_calibration || return 1
  mirror_dataset "$target_dir" raw/droid/calibration || return 1
  mirror_manifest "$MANIFEST_ROOT/droid_calibration_files.tsv" droid_calibration_files.tsv || return 1
  mirror_manifest "$MANIFEST_ROOT/droid_calibration_sha256.txt" droid_calibration_sha256.txt || return 1
  mirror_manifest "$MANIFEST_ROOT/droid_calibration_source.json" droid_calibration_source.json || return 1
}

download_droid_lerobot_sample() {
  local target_dir="$RAW_ROOT/droid/lerobot_sample"

  download_hf_exact_files \
    "lerobot/droid_1.0.1" \
    "$target_dir" \
    "meta/info.json" \
    "meta/stats.json" \
    "meta/tasks.parquet" \
    "data/chunk-000/file-000.parquet" \
    "videos/observation.images.exterior_1_left/chunk-000/file-000.mp4" \
    "videos/observation.images.exterior_2_left/chunk-000/file-000.mp4" \
    "videos/observation.images.wrist_left/chunk-000/file-000.mp4" \
    || return 1

  write_hf_source_manifest droid_lerobot_sample lerobot/droid_1.0.1 || return 1
  write_file_manifests "$target_dir" droid_lerobot_sample || return 1
  mirror_dataset "$target_dir" raw/droid/lerobot_sample || return 1
  mirror_manifest "$MANIFEST_ROOT/droid_lerobot_sample_files.tsv" droid_lerobot_sample_files.tsv || return 1
  mirror_manifest "$MANIFEST_ROOT/droid_lerobot_sample_sha256.txt" droid_lerobot_sample_sha256.txt || return 1
  mirror_manifest "$MANIFEST_ROOT/droid_lerobot_sample_source.json" droid_lerobot_sample_source.json || return 1
}

download_bridgedata_v2_sample() {
  local target_dir="$RAW_ROOT/bridgedata_v2/sample"

  if [[ -n "$OPENXLAB_BIN" ]]; then
    openxlab_cli dataset info --dataset-repo OpenDataLab/BridgeData_V2 | tee "$MANIFEST_ROOT/bridgedata_v2_info.txt" || true
  fi

  download_hf_exact_files \
    "$BRIDGE_HF_REPO" \
    "$target_dir" \
    "$BRIDGE_HF_FILE" \
    || return 1

  write_bridge_source_manifest || return 1
  write_file_manifests "$target_dir" bridgedata_v2_sample || return 1
  mirror_dataset "$target_dir" raw/bridgedata_v2/sample || return 1
  if [[ -f "$MANIFEST_ROOT/bridgedata_v2_info.txt" ]]; then
    mirror_manifest "$MANIFEST_ROOT/bridgedata_v2_info.txt" bridgedata_v2_info.txt || return 1
  fi
  mirror_manifest "$MANIFEST_ROOT/bridgedata_v2_sample_files.tsv" bridgedata_v2_sample_files.tsv || return 1
  mirror_manifest "$MANIFEST_ROOT/bridgedata_v2_sample_sha256.txt" bridgedata_v2_sample_sha256.txt || return 1
  mirror_manifest "$MANIFEST_ROOT/bridgedata_v2_sample_source.json" bridgedata_v2_sample_source.json || return 1
}

download_robomimic_sample() {
  local target_dir="$RAW_ROOT/robomimic/sample"

  download_hf_exact_files \
    "robomimic/robomimic_datasets" \
    "$target_dir" \
    "README.md" \
    "v1.5/can/ph/low_dim_v15.hdf5" \
    || return 1

  write_hf_source_manifest robomimic_sample robomimic/robomimic_datasets || return 1
  write_file_manifests "$target_dir" robomimic_sample || return 1
  mirror_dataset "$target_dir" raw/robomimic/sample || return 1
  mirror_manifest "$MANIFEST_ROOT/robomimic_sample_files.tsv" robomimic_sample_files.tsv || return 1
  mirror_manifest "$MANIFEST_ROOT/robomimic_sample_sha256.txt" robomimic_sample_sha256.txt || return 1
  mirror_manifest "$MANIFEST_ROOT/robomimic_sample_source.json" robomimic_sample_source.json || return 1
}

run_step() {
  local label="$1"
  shift

  echo "== $label =="
  if "$@"; then
    echo "$label completed."
  else
    echo "$label failed." >&2
    STATUS=1
  fi
  echo
}

ensure_writable_dataset_dirs
configure_hf_endpoint || exit 1
setup_mc_alias

if [[ $RUN_DROID_CALIBRATION -eq 1 ]]; then
  run_step "droid calibration" download_droid_calibration
fi

if [[ $RUN_DROID_LEROBOT -eq 1 ]]; then
  run_step "droid lerobot sample" download_droid_lerobot_sample
fi

if [[ $RUN_BRIDGE -eq 1 ]]; then
  run_step "bridgeData V2 sample" download_bridgedata_v2_sample
fi

if [[ $RUN_ROBOMIMIC -eq 1 ]]; then
  run_step "robomimic sample" download_robomimic_sample
fi

if [[ -x "$SCRIPT_DIR/15_audit_raw_datasets.sh" ]]; then
  "$SCRIPT_DIR/15_audit_raw_datasets.sh"
  mirror_manifest "$MANIFEST_ROOT/raw_dataset_summary.txt" raw_dataset_summary.txt
fi

exit "$STATUS"
