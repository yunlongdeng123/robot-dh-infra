#!/usr/bin/env bash
set -euo pipefail

# 拉取约 30GB 规模的真实机器人数据集到本地 raw 区，
# 并镜像到 MinIO 的 robot-datasets/raw，给 v1.4 raw -> ods -> dwd -> ads 链路压数据。
#
# 用法：
#   TARGET_GB=30 ./scripts/25_pull_scale_30gb_hf.sh
#
# 可调环境变量：
#   TARGET_GB        总预算（GiB），默认 30
#   LOCAL_ROOT       本地落盘根目录，默认 /data/robot-dh/datasets/raw/scale30
#   MANIFEST_ROOT    清单目录，默认 /data/robot-dh/datasets/manifests/scale30
#   HF_HOME          huggingface 缓存目录，默认 /data/robot-dh/cache/huggingface
#   HF_ENDPOINT      显式指定 HF 端点。未设置时默认走 hf-mirror。
#                    海外节点可 `HF_ENDPOINT=https://huggingface.co` 覆盖。
#   HF_MIRROR_URL    自定义镜像地址，默认 https://hf-mirror.com
#   SKIP_MIRROR=1    跳过 mc mirror 上传 MinIO 步骤（仅本地落盘）

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
ENV_FILE="$PROJECT_DIR/.env"

TARGET_GB="${TARGET_GB:-30}"
LOCAL_ROOT="${LOCAL_ROOT:-/data/robot-dh/datasets/raw/scale30}"
MANIFEST_ROOT="${MANIFEST_ROOT:-/data/robot-dh/datasets/manifests/scale30}"
HF_HOME_DIR="${HF_HOME:-/data/robot-dh/cache/huggingface}"
SKIP_MIRROR="${SKIP_MIRROR:-0}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE not found. Run ./scripts/03_generate_env.sh first." >&2
  exit 1
fi

# 必要工具检查；mc / python3 / sha256sum 都由 13_install_dataset_tools.sh 提供
for required_cmd in python3 mc sha256sum find sort curl; do
  if ! command -v "$required_cmd" >/dev/null 2>&1; then
    echo "ERROR: Missing required command: $required_cmd. Run ./scripts/13_install_dataset_tools.sh first." >&2
    exit 1
  fi
done

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

: "${MINIO_ROOT_USER:?MINIO_ROOT_USER missing in .env}"
: "${MINIO_ROOT_PASSWORD:?MINIO_ROOT_PASSWORD missing in .env}"
: "${ROBOT_DH_DATA_BUCKET:?ROBOT_DH_DATA_BUCKET missing in .env}"

export HF_HOME="$HF_HOME_DIR"
# 单独大文件用普通 HTTP 下载更稳；强行开启 hf_transfer 在断点续传时会偶发崩溃
unset HF_HUB_ENABLE_HF_TRANSFER
export HF_XET_HIGH_PERFORMANCE="${HF_XET_HIGH_PERFORMANCE:-1}"

mkdir -p "$LOCAL_ROOT" "$MANIFEST_ROOT" "$HF_HOME" /data/robot-dh/logs

# 默认走 hf-mirror，国内节点直连 huggingface.co 必 timeout。
# 用户显式 export HF_ENDPOINT 时尊重其设置（例如海外节点走官方源）。
HF_MIRROR_URL="${HF_MIRROR_URL:-https://hf-mirror.com}"
if [[ -z "${HF_ENDPOINT:-}" ]]; then
  export HF_ENDPOINT="$HF_MIRROR_URL"
fi

# 只对最终选定的 endpoint 做一次连通性探测，失败直接退出，避免 tqdm 拉一半才挂
if ! curl -fsS --max-time 15 -o /dev/null "$HF_ENDPOINT"; then
  echo "ERROR: HF endpoint $HF_ENDPOINT unreachable." >&2
  echo "       请确认网络，或显式 export HF_ENDPOINT=<可达地址> 后重试。" >&2
  exit 1
fi
echo "Using HF endpoint: $HF_ENDPOINT"

# huggingface_hub / tqdm 由 13_install_dataset_tools.sh 安装，这里只校验
if ! python3 -c "import huggingface_hub, tqdm" >/dev/null 2>&1; then
  echo "ERROR: huggingface_hub / tqdm not available. Run ./scripts/13_install_dataset_tools.sh first." >&2
  exit 1
fi

mc alias set rdh http://127.0.0.1:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null
mc mb --ignore-existing "rdh/$ROBOT_DH_DATA_BUCKET" >/dev/null

echo "== Plan =="
echo "TARGET_GB       = $TARGET_GB"
echo "LOCAL_ROOT      = $LOCAL_ROOT"
echo "MANIFEST_ROOT   = $MANIFEST_ROOT"
echo "HF_HOME         = $HF_HOME"
echo "HF_ENDPOINT     = $HF_ENDPOINT"
echo "DATA_BUCKET     = rdh/$ROBOT_DH_DATA_BUCKET"
echo

python3 - "$TARGET_GB" "$LOCAL_ROOT" "$MANIFEST_ROOT" <<'PY'
from __future__ import annotations

import json
import os
import sys
import urllib.parse
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

from huggingface_hub import HfApi, hf_hub_download
from tqdm import tqdm

# 修复 hf-mirror 等代理场景下 huggingface_hub 分页 Link header 仍指向 huggingface.co 的 bug：
# 强制把 next page URL 的域名改写到当前 HF_ENDPOINT。
_HF_ENDPOINT = os.environ.get("HF_ENDPOINT", "").strip()
if _HF_ENDPOINT:
    _MIRROR_NETLOC = urllib.parse.urlparse(_HF_ENDPOINT).netloc

    from huggingface_hub.utils import _pagination as _hub_pagination

    def _patched_get_next_page(response):  # type: ignore[no-untyped-def]
        url = response.links.get("next", {}).get("url")
        if not url:
            return None
        parsed = urllib.parse.urlparse(url)
        if parsed.netloc and parsed.netloc != _MIRROR_NETLOC:
            url = parsed._replace(netloc=_MIRROR_NETLOC, scheme="https").geturl()
        return url

    _hub_pagination._get_next_page = _patched_get_next_page
    print(f"[patch] pagination next-page host forced to {_MIRROR_NETLOC}", file=sys.stderr)

TARGET_GB: float = float(sys.argv[1])
LOCAL_ROOT: Path = Path(sys.argv[2]).expanduser().resolve()
MANIFEST_ROOT: Path = Path(sys.argv[3]).expanduser().resolve()
GIB: int = 1024 ** 3
TOTAL_BUDGET: int = int(TARGET_GB * GIB)

LOCAL_ROOT.mkdir(parents=True, exist_ok=True)
MANIFEST_ROOT.mkdir(parents=True, exist_ok=True)


@dataclass
class Plan:
    """单个 HF 数据集的拉取计划。"""

    repo_id: str
    dataset_id: str
    version: str
    budget_ratio: float
    priority_prefixes: tuple[str, ...]
    suffixes: tuple[str, ...]
    always_include_prefixes: tuple[str, ...] = ("meta/",)
    always_include_suffixes: tuple[str, ...] = (
        ".json",
        ".jsonl",
        ".yaml",
        ".yml",
        ".md",
        ".txt",
    )


# 三类机器人数据混合：DROID 末端位姿+多相机 MP4，robomimic 演示 HDF5，BridgeData V2 EEF parquet
PLANS: list[Plan] = [
    Plan(
        repo_id="lerobot/droid_1.0.1",
        dataset_id="droid_lerobot_scale30",
        version="v1",
        budget_ratio=0.60,
        priority_prefixes=("data/", "videos/", "meta/"),
        suffixes=(".parquet", ".mp4", ".json", ".md"),
    ),
    Plan(
        repo_id="robomimic/robomimic_datasets",
        dataset_id="robomimic_scale30",
        version="v1",
        budget_ratio=0.25,
        priority_prefixes=("v1.5/", "v1.4/", "v1.0/"),
        suffixes=(".hdf5", ".h5", ".json", ".md"),
    ),
    Plan(
        repo_id="mbodiai/oxe_bridge_v2",
        dataset_id="bridgedata_v2_scale30",
        version="v1",
        budget_ratio=0.15,
        priority_prefixes=("data/",),
        suffixes=(".parquet", ".json", ".md"),
    ),
]


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def list_repo_files(api: HfApi, repo_id: str) -> list[dict]:
    """列出 repo 下所有文件 + size；老版本 hub 不支持 expand 参数时降级。"""

    try:
        items = api.list_repo_tree(
            repo_id=repo_id,
            repo_type="dataset",
            recursive=True,
            expand=True,
        )
    except TypeError:
        items = api.list_repo_tree(
            repo_id=repo_id,
            repo_type="dataset",
            recursive=True,
        )

    out: list[dict] = []
    for item in items:
        path = getattr(item, "path", None)
        if not path or path.endswith("/"):
            continue
        size = getattr(item, "size", None)
        out.append({"path": path, "size": int(size) if size is not None else None})
    return out


def should_take(plan: Plan, path: str) -> bool:
    lower = path.lower()
    if any(lower.startswith(p.lower()) for p in plan.priority_prefixes):
        if lower.endswith(plan.suffixes):
            return True
    if lower.endswith(plan.always_include_suffixes):
        return True
    return False


def is_metadata(plan: Plan, path: str) -> bool:
    lower = path.lower()
    return any(lower.startswith(p.lower()) for p in plan.always_include_prefixes) or lower.endswith(
        plan.always_include_suffixes
    )


def priority_key(path: str) -> tuple[int, str]:
    """优先级排序：先 meta，再小文本，再首个 chunk，最后视频。"""

    lower = path.lower()
    if lower.startswith("meta/"):
        return (0, path)
    if lower.endswith((".json", ".jsonl", ".yaml", ".yml", ".md", ".txt")):
        return (1, path)
    if "file-000" in lower:
        return (2, path)
    if lower.endswith(".parquet"):
        return (3, path)
    if lower.endswith((".hdf5", ".h5")):
        return (4, path)
    if lower.endswith(".mp4"):
        return (5, path)
    return (9, path)


def select_files(plan: Plan, files: list[dict], budget: int) -> list[dict]:
    """在预算范围内按优先级挑文件；meta 类小文件强制全选。"""

    candidates = [f for f in files if should_take(plan, f["path"])]
    candidates.sort(key=lambda f: priority_key(f["path"]))

    selected: list[dict] = []
    used = 0

    # meta 先全部塞进去，不计预算上限
    for f in candidates:
        if is_metadata(plan, f["path"]):
            selected.append(f)
            used += int(f["size"] or 0)

    seen = {f["path"] for f in selected}

    for f in candidates:
        if f["path"] in seen:
            continue
        size = f["size"]
        # 未知大小的非 meta 文件跳过，避免一个意外巨型文件撑爆预算
        if size is None:
            continue
        if used + size > budget and used > 0:
            continue
        selected.append(f)
        used += size
        seen.add(f["path"])
        if used >= budget:
            break

    return selected


def file_size(path: Path) -> int:
    if not path.exists() or not path.is_file():
        return 0
    return path.stat().st_size


api = HfApi()
global_manifest: dict = {
    "target_gb": TARGET_GB,
    "target_bytes": TOTAL_BUDGET,
    "started_at": now_iso(),
    "repos": [],
}

total_downloaded = 0

for plan in PLANS:
    repo_budget = int(TOTAL_BUDGET * plan.budget_ratio)
    print(
        f"\n=== Plan {plan.dataset_id}: repo={plan.repo_id}, "
        f"budget={repo_budget / GIB:.2f} GiB ==="
    )

    try:
        files = list_repo_files(api, plan.repo_id)
    except Exception as err:
        print(f"WARNING: list failed for {plan.repo_id}: {err}", file=sys.stderr)
        global_manifest["repos"].append(
            {
                "repo_id": plan.repo_id,
                "dataset_id": plan.dataset_id,
                "status": "LIST_FAILED",
                "error": str(err),
            }
        )
        continue

    selected = select_files(plan, files, repo_budget)
    if not selected:
        print(f"WARNING: no selected files for {plan.repo_id}")
        global_manifest["repos"].append(
            {
                "repo_id": plan.repo_id,
                "dataset_id": plan.dataset_id,
                "status": "NO_FILES_SELECTED",
            }
        )
        continue

    target_dir = LOCAL_ROOT / plan.dataset_id / plan.version
    target_dir.mkdir(parents=True, exist_ok=True)

    repo_manifest: dict = {
        "repo_id": plan.repo_id,
        "dataset_id": plan.dataset_id,
        "version": plan.version,
        "target_dir": str(target_dir),
        "budget_bytes": repo_budget,
        "selected_files": selected,
        "downloaded_files": [],
        "failed_files": [],
        "started_at": now_iso(),
        "status": "RUNNING",
    }

    for f in tqdm(selected, desc=plan.dataset_id):
        path = f["path"]
        try:
            local_path = hf_hub_download(
                repo_id=plan.repo_id,
                repo_type="dataset",
                filename=path,
                local_dir=str(target_dir),
            )
            p = Path(local_path)
            size = file_size(p)
            repo_manifest["downloaded_files"].append(
                {
                    "path": path,
                    "local_path": str(p),
                    "size_bytes": size,
                    "expected_size_bytes": f.get("size"),
                }
            )
            total_downloaded += size
        except Exception as err:
            print(
                f"WARNING: download failed: {plan.repo_id}:{path}: {err}",
                file=sys.stderr,
            )
            repo_manifest["failed_files"].append({"path": path, "error": str(err)})

    repo_manifest["finished_at"] = now_iso()
    repo_manifest["downloaded_bytes"] = sum(
        x["size_bytes"] for x in repo_manifest["downloaded_files"]
    )
    repo_manifest["downloaded_gib"] = round(repo_manifest["downloaded_bytes"] / GIB, 3)
    repo_manifest["status"] = "OK" if repo_manifest["downloaded_files"] else "EMPTY"

    # raw 层每个 dataset 写一份 _manifest.json，便于 ETL 适配器直接读取血缘信息
    raw_manifest = {
        "dataset_id": plan.dataset_id,
        "version": plan.version,
        "layer": "raw",
        "created_at": now_iso(),
        "schema_version": "v1.4-scale30",
        "source_repo": plan.repo_id,
        "source_uris": [f"hf://datasets/{plan.repo_id}"],
        "files": repo_manifest["downloaded_files"],
        "metrics": {
            "downloaded_bytes": repo_manifest["downloaded_bytes"],
            "downloaded_gib": repo_manifest["downloaded_gib"],
        },
    }
    (target_dir / "_manifest.json").write_text(
        json.dumps(raw_manifest, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )

    manifest_path = MANIFEST_ROOT / f"{plan.dataset_id}_{plan.version}_download_manifest.json"
    manifest_path.write_text(
        json.dumps(repo_manifest, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )

    global_manifest["repos"].append(repo_manifest)

global_manifest["finished_at"] = now_iso()
global_manifest["downloaded_bytes"] = total_downloaded
global_manifest["downloaded_gib"] = round(total_downloaded / GIB, 3)

global_path = MANIFEST_ROOT / "scale30_download_manifest.json"
global_path.write_text(
    json.dumps(global_manifest, ensure_ascii=False, indent=2),
    encoding="utf-8",
)

print("\n=== Download summary ===")
print(
    json.dumps(
        {
            "target_gb": TARGET_GB,
            "downloaded_gib": global_manifest["downloaded_gib"],
            "manifest": str(global_path),
        },
        ensure_ascii=False,
        indent=2,
    )
)
PY

echo
echo "== Local raw size =="
du -sh "$LOCAL_ROOT" || true
du -sh "$HF_HOME" || true

echo
echo "== Writing checksums =="
# 完整校验和；体量大时这一步会比较慢，但属于离线后台动作不阻塞下载
( cd "$LOCAL_ROOT" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum ) \
  > "$MANIFEST_ROOT/scale30_sha256.txt"

if [[ "$SKIP_MIRROR" == "1" ]]; then
  echo
  echo "SKIP_MIRROR=1, skipping MinIO mirror step."
else
  echo
  echo "== Mirroring to MinIO =="
  for dataset_dir in "$LOCAL_ROOT"/*; do
    [[ -d "$dataset_dir" ]] || continue
    dataset_id=$(basename "$dataset_dir")
    for version_dir in "$dataset_dir"/*; do
      [[ -d "$version_dir" ]] || continue
      version=$(basename "$version_dir")
      echo "Mirroring $dataset_id/$version -> rdh/$ROBOT_DH_DATA_BUCKET/raw/$dataset_id/$version"
      mc mirror --overwrite "$version_dir" \
        "rdh/$ROBOT_DH_DATA_BUCKET/raw/$dataset_id/$version"
    done
  done

  echo
  echo "== Uploading manifests =="
  mc mirror --overwrite "$MANIFEST_ROOT" \
    "rdh/$ROBOT_DH_DATA_BUCKET/manifests/scale30"

  echo
  echo "== MinIO raw summary (tail 50) =="
  mc ls --recursive "rdh/$ROBOT_DH_DATA_BUCKET/raw" | tail -50 || true
fi

echo
echo "DONE: scale30 data pull completed."
