#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
ENV_FILE="$PROJECT_DIR/.env"
LOG_ROOT="/data/robot-dh/logs"
TIMESTAMP=$(date -u +%Y%m%d_%H%M%S)
OUT_FILE="$LOG_ROOT/remote_assets_${TIMESTAMP}.json"
TMP_DIR=$(mktemp -d)

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE not found. Run ./scripts/03_generate_env.sh first." >&2
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker is not installed." >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 is required for JSON report generation." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

ROBOT_DH_LAKE_BUCKET="${ROBOT_DH_LAKE_BUCKET:-robot-lake}"
mkdir -p "$LOG_ROOT"

run_ls_json() {
  local target="$1"
  local output_file="$2"

  docker run --rm \
    --entrypoint sh \
    --network robot-dh-net \
    -e MINIO_ROOT_USER="$MINIO_ROOT_USER" \
    -e MINIO_ROOT_PASSWORD="$MINIO_ROOT_PASSWORD" \
    minio/mc:latest \
    -c "set -eu; mc alias set local http://robot-dh-minio:9000 \"\$MINIO_ROOT_USER\" \"\$MINIO_ROOT_PASSWORD\" >/dev/null; mc ls --recursive --json '$target'" > "$output_file"
}

DATA_JSON="$TMP_DIR/robot_datasets_raw.jsonl"
LAKE_JSON="$TMP_DIR/robot_lake_raw.jsonl"

run_ls_json "local/$ROBOT_DH_DATA_BUCKET/raw/" "$DATA_JSON"
run_ls_json "local/$ROBOT_DH_LAKE_BUCKET/raw/" "$LAKE_JSON"

python3 - "$DATA_JSON" "$LAKE_JSON" "$OUT_FILE" "$ROBOT_DH_DATA_BUCKET" "$ROBOT_DH_LAKE_BUCKET" <<'PY'
from __future__ import annotations

import json
import sys
from datetime import datetime, timezone
from pathlib import Path


DATA_EXTENSIONS = {
    ".parquet",
    ".hdf5",
    ".h5",
    ".mp4",
    ".pt",
    ".json",
    ".jsonl",
    ".yaml",
    ".yml",
    ".csv",
    ".zip",
    ".tar",
    ".zst",
}
EXPECTED_FILES = ("endpose.pt", "video.mp4", "meta.yaml")


def now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def load_json_lines(path: Path) -> list[dict]:
    entries = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        payload = json.loads(line)
        if payload.get("status") == "success" and payload.get("type") == "file":
            entries.append(payload)
    return entries


def is_data_bearing(key: str) -> bool:
    if key.endswith("/.keep") or "/.cache/" in key:
        return False
    suffix = Path(key).suffix.lower()
    return suffix in DATA_EXTENSIONS


def discover_candidates(source: str, bucket: str, entries: list[dict]) -> list[dict]:
    candidates: dict[tuple[str, str], dict] = {}

    for entry in entries:
        key = str(entry.get("key", "")).strip("/")
        if not key or key == ".keep":
            continue

        parts = key.split("/")
        if len(parts) < 2:
            continue

        dataset_id, version = parts[0], parts[1]
        candidate = candidates.setdefault(
            (dataset_id, version),
            {
                "source": source,
                "bucket": bucket,
                "dataset_id": dataset_id,
                "version": version,
                "prefix": f"raw/{dataset_id}/{version}/",
                "uri": f"s3://{bucket}/raw/{dataset_id}/{version}/",
                "object_count": 0,
                "total_size_bytes": 0,
                "checks": {name: False for name in EXPECTED_FILES},
                "sample_files": [],
                "data_file_count": 0,
            },
        )

        candidate["object_count"] += 1
        candidate["total_size_bytes"] += int(entry.get("size", 0))

        if len(candidate["sample_files"]) < 8:
            candidate["sample_files"].append(key)

        basename = parts[-1]
        if basename in candidate["checks"]:
            candidate["checks"][basename] = True

        if is_data_bearing(key):
            candidate["data_file_count"] += 1

    filtered = [candidate for candidate in candidates.values() if candidate["data_file_count"] > 0]
    filtered.sort(key=lambda item: (item["source"], item["dataset_id"], item["version"]))
    return filtered


data_json = Path(sys.argv[1])
lake_json = Path(sys.argv[2])
out_path = Path(sys.argv[3])
data_bucket = sys.argv[4]
lake_bucket = sys.argv[5]

robot_datasets_entries = load_json_lines(data_json)
robot_lake_entries = load_json_lines(lake_json)

candidates = discover_candidates("robot-datasets/raw", data_bucket, robot_datasets_entries)
candidates.extend(discover_candidates("robot-lake/raw", lake_bucket, robot_lake_entries))

report = {
    "generated_at": now_iso(),
    "scan_targets": [
        f"s3://{data_bucket}/raw/",
        f"s3://{lake_bucket}/raw/",
    ],
    "candidate_count": len(candidates),
    "candidates": candidates,
}

out_path.write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")

print(f"Wrote JSON report: {out_path}")
print()
print(f"{'SOURCE':<20} {'DATASET_ID':<24} {'VERSION':<20} {'OBJECTS':>7} {'ENDPOSE':>8} {'VIDEO':>8} {'META':>8}")
print("-" * 106)
for candidate in candidates:
    checks = candidate["checks"]
    print(
        f"{candidate['source']:<20} "
        f"{candidate['dataset_id']:<24} "
        f"{candidate['version']:<20} "
        f"{candidate['object_count']:>7} "
        f"{str(checks['endpose.pt']):>8} "
        f"{str(checks['video.mp4']):>8} "
        f"{str(checks['meta.yaml']):>8}"
    )
    print(f"  uri: {candidate['uri']}")
    print(f"  sample_files: {', '.join(candidate['sample_files'])}")
    print()

if not candidates:
    print("No candidate dataset directories were discovered under the scanned MinIO prefixes.")
PY
