#!/usr/bin/env bash
set -euo pipefail

# v1.5 scale30 数据资产审计（read-only）。
#
# 对比三个数据集 (droid_lerobot_scale30 / robomimic_scale30 / bridgedata_v2_scale30)：
#   - 本地 raw 目录文件数 / 字节数
#   - MinIO robot-datasets/raw/<dataset>/v1/ 文件数 / 字节数
#   - manifest 中的 downloaded_files 列表
#
# 输出三件套：
#   - missing_local：manifest 有、本地缺
#   - missing_minio：manifest 有、MinIO 缺
#   - wrong_size：本地或 MinIO 与 manifest size 不一致
#
# 安全约束：
#   - 不删除数据
#   - 不上传 / 下载数据
#   - 可重复执行；只读
#
# 用法：
#   ./scripts/27_audit_scale30_assets.sh
#
# 输出文件：
#   /data/robot-dh/datasets/manifests/scale30/scale30_audit_YYYYmmdd_HHMMSS.json
#   /data/robot-dh/datasets/manifests/scale30/scale30_audit_YYYYmmdd_HHMMSS.md

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
ENV_FILE="$PROJECT_DIR/.env"

LOCAL_ROOT="/data/robot-dh/datasets/raw/scale30"
MANIFEST_ROOT="/data/robot-dh/datasets/manifests/scale30"
MINIO_PREFIX_TEMPLATE="raw/{dataset}/v1"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE not found." >&2
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker is not installed." >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 is required." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

ROBOT_DH_DATA_BUCKET="${ROBOT_DH_DATA_BUCKET:-robot-datasets}"

mkdir -p "$MANIFEST_ROOT"

TIMESTAMP=$(date -u +%Y%m%d_%H%M%S)
OUT_JSON="$MANIFEST_ROOT/scale30_audit_${TIMESTAMP}.json"
OUT_MD="$MANIFEST_ROOT/scale30_audit_${TIMESTAMP}.md"

TMP_DIR=$(mktemp -d)
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

DATASETS=(droid_lerobot_scale30 robomimic_scale30 bridgedata_v2_scale30)

# 拉取 MinIO 对象清单（仅在容器在线时）。
MINIO_READY=0
if docker inspect robot-dh-minio >/dev/null 2>&1; then
  if docker run --rm --entrypoint sh --network robot-dh-net \
      -e MINIO_ROOT_USER="$MINIO_ROOT_USER" \
      -e MINIO_ROOT_PASSWORD="$MINIO_ROOT_PASSWORD" \
      minio/mc:latest -c "mc alias set local http://robot-dh-minio:9000 \"\$MINIO_ROOT_USER\" \"\$MINIO_ROOT_PASSWORD\" >/dev/null && mc ready local >/dev/null 2>&1"; then
    MINIO_READY=1
  fi
fi

for dataset in "${DATASETS[@]}"; do
  local_listing="$TMP_DIR/${dataset}.local.tsv"
  minio_listing="$TMP_DIR/${dataset}.minio.jsonl"

  : > "$local_listing"
  : > "$minio_listing"

  if [[ -d "$LOCAL_ROOT/$dataset/v1" ]]; then
    (cd "$LOCAL_ROOT/$dataset/v1" && find . -type f -printf '%P\t%s\n') > "$local_listing"
  fi

  if [[ "$MINIO_READY" -eq 1 ]]; then
    prefix="raw/${dataset}/v1/"
    docker run --rm --entrypoint sh --network robot-dh-net \
      -e MINIO_ROOT_USER="$MINIO_ROOT_USER" \
      -e MINIO_ROOT_PASSWORD="$MINIO_ROOT_PASSWORD" \
      minio/mc:latest \
      -c "set -eu; mc alias set local http://robot-dh-minio:9000 \"\$MINIO_ROOT_USER\" \"\$MINIO_ROOT_PASSWORD\" >/dev/null; mc ls --recursive --json local/${ROBOT_DH_DATA_BUCKET}/${prefix}" > "$minio_listing" 2>/dev/null || true
  fi
done

python3 - "$LOCAL_ROOT" "$MANIFEST_ROOT" "$TMP_DIR" "$OUT_JSON" "$OUT_MD" \
    "$ROBOT_DH_DATA_BUCKET" "$MINIO_READY" "${DATASETS[@]}" <<'PY'
import json, os, sys
from datetime import datetime, timezone
from pathlib import Path

(local_root, manifest_root, tmp_dir, out_json, out_md,
 data_bucket, minio_ready_str, *datasets) = sys.argv[1:]
minio_ready = minio_ready_str == "1"

def now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

def gib(n):
    try:
        return round(int(n) / 1024 / 1024 / 1024, 4)
    except (TypeError, ValueError):
        return None

def load_local(dataset: str) -> dict[str, int]:
    p = Path(tmp_dir) / f"{dataset}.local.tsv"
    out: dict[str, int] = {}
    if not p.exists():
        return out
    for line in p.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        parts = line.split("\t")
        if len(parts) != 2:
            continue
        try:
            out[parts[0].lstrip("./")] = int(parts[1])
        except ValueError:
            continue
    return out

def load_minio(dataset: str) -> dict[str, int]:
    p = Path(tmp_dir) / f"{dataset}.minio.jsonl"
    out: dict[str, int] = {}
    if not p.exists():
        return out
    prefix = f"raw/{dataset}/v1/"
    for line in p.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        if row.get("status") != "success" or row.get("type") != "file":
            continue
        key = str(row.get("key", "")).lstrip("/")
        # mc ls 在使用 prefix 时返回的 key 可能是相对路径；剥掉 bucket 名再剥 prefix。
        if key.startswith(f"{data_bucket}/"):
            key = key[len(data_bucket) + 1 :]
        if key.startswith(prefix):
            rel = key[len(prefix):]
        else:
            rel = key
        try:
            out[rel] = int(row.get("size", 0))
        except (TypeError, ValueError):
            continue
    return out

def load_manifest(dataset: str) -> dict[str, int]:
    candidates = list(Path(manifest_root).glob(f"{dataset}_v1_download_manifest.json"))
    if not candidates:
        return {}
    payload = json.loads(candidates[0].read_text(encoding="utf-8"))
    out: dict[str, int] = {}
    for f in payload.get("downloaded_files") or []:
        path = f.get("path") or ""
        size = f.get("size_bytes") or f.get("size") or 0
        if path:
            try:
                out[path] = int(size)
            except (TypeError, ValueError):
                continue
    # 兜底：如果没有 downloaded_files，就退而求其次用 selected_files
    if not out:
        for f in payload.get("selected_files") or []:
            path = f.get("path") or ""
            size = f.get("size") or 0
            if path:
                try:
                    out[path] = int(size)
                except (TypeError, ValueError):
                    continue
    return out

datasets_report: list[dict] = []
overall = {
    "local_files": 0, "local_bytes": 0,
    "minio_objects": 0, "minio_bytes": 0,
    "missing_local": 0, "missing_minio": 0, "wrong_size": 0,
}

for dataset in datasets:
    local = load_local(dataset)
    minio = load_minio(dataset)
    manifest = load_manifest(dataset)

    missing_local: list[dict] = []
    missing_minio: list[dict] = []
    wrong_size: list[dict] = []

    expected_keys = set(manifest)
    for key, expected in manifest.items():
        if key not in local:
            missing_local.append({"path": key, "expected_size": expected})
        elif local[key] != expected:
            wrong_size.append({
                "path": key, "where": "local",
                "expected": expected, "actual": local[key],
            })
        if minio_ready:
            if key not in minio:
                missing_minio.append({"path": key, "expected_size": expected})
            elif minio[key] != expected:
                wrong_size.append({
                    "path": key, "where": "minio",
                    "expected": expected, "actual": minio[key],
                })

    sample_files = sorted(local.keys())[:8]

    local_bytes = sum(local.values())
    minio_bytes = sum(minio.values())

    item = {
        "dataset": dataset,
        "local_root": str(Path(local_root) / dataset / "v1"),
        "minio_uri": f"s3://{data_bucket}/raw/{dataset}/v1/",
        "manifest_files": len(manifest),
        "local_files": len(local),
        "local_bytes": local_bytes,
        "local_gib": gib(local_bytes),
        "minio_objects": len(minio),
        "minio_bytes": minio_bytes,
        "minio_gib": gib(minio_bytes),
        "missing_local": missing_local,
        "missing_minio": missing_minio,
        "wrong_size": wrong_size,
        "sample_files": sample_files,
        "minio_ready": minio_ready,
    }
    datasets_report.append(item)

    overall["local_files"] += len(local)
    overall["local_bytes"] += local_bytes
    overall["minio_objects"] += len(minio)
    overall["minio_bytes"] += minio_bytes
    overall["missing_local"] += len(missing_local)
    overall["missing_minio"] += len(missing_minio)
    overall["wrong_size"] += len(wrong_size)

report = {
    "generated_at": now_iso(),
    "data_bucket": data_bucket,
    "minio_ready": minio_ready,
    "overall": {
        **overall,
        "local_gib": gib(overall["local_bytes"]),
        "minio_gib": gib(overall["minio_bytes"]),
    },
    "datasets": datasets_report,
}

Path(out_json).write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")

# Markdown 报告
md_lines: list[str] = []
md_lines.append(f"# scale30 资产审计报告\n")
md_lines.append(f"- 生成时间: `{report['generated_at']}`")
md_lines.append(f"- 数据 bucket: `{data_bucket}`")
md_lines.append(f"- MinIO 可达: `{minio_ready}`\n")
md_lines.append("## 汇总\n")
md_lines.append("| 维度 | 值 |")
md_lines.append("|------|----|")
md_lines.append(f"| local_files | {overall['local_files']} |")
md_lines.append(f"| local_gib   | {gib(overall['local_bytes'])} |")
md_lines.append(f"| minio_objects | {overall['minio_objects']} |")
md_lines.append(f"| minio_gib | {gib(overall['minio_bytes'])} |")
md_lines.append(f"| missing_local | {overall['missing_local']} |")
md_lines.append(f"| missing_minio | {overall['missing_minio']} |")
md_lines.append(f"| wrong_size | {overall['wrong_size']} |\n")

for item in datasets_report:
    md_lines.append(f"## {item['dataset']}\n")
    md_lines.append("| 维度 | 值 |")
    md_lines.append("|------|----|")
    md_lines.append(f"| local_root | `{item['local_root']}` |")
    md_lines.append(f"| minio_uri | `{item['minio_uri']}` |")
    md_lines.append(f"| manifest_files | {item['manifest_files']} |")
    md_lines.append(f"| local_files | {item['local_files']} |")
    md_lines.append(f"| local_gib | {item['local_gib']} |")
    md_lines.append(f"| minio_objects | {item['minio_objects']} |")
    md_lines.append(f"| minio_gib | {item['minio_gib']} |")
    md_lines.append(f"| missing_local | {len(item['missing_local'])} |")
    md_lines.append(f"| missing_minio | {len(item['missing_minio'])} |")
    md_lines.append(f"| wrong_size | {len(item['wrong_size'])} |\n")

    if item["sample_files"]:
        md_lines.append("Sample files:\n")
        for f in item["sample_files"]:
            md_lines.append(f"- `{f}`")
        md_lines.append("")

    def render_top(name: str, rows: list[dict], limit: int = 10) -> None:
        if not rows:
            return
        md_lines.append(f"前 {min(limit, len(rows))} 条 {name}:\n")
        md_lines.append("| path | detail |")
        md_lines.append("|------|--------|")
        for r in rows[:limit]:
            md_lines.append(f"| `{r.get('path')}` | {json.dumps({k:v for k,v in r.items() if k != 'path'}, ensure_ascii=False)} |")
        md_lines.append("")

    render_top("missing_local", item["missing_local"])
    render_top("missing_minio", item["missing_minio"])
    render_top("wrong_size", item["wrong_size"])

Path(out_md).write_text("\n".join(md_lines) + "\n", encoding="utf-8")

print("scale30 audit done.")
print(f"  JSON: {out_json}")
print(f"  MD:   {out_md}")
print()
print(f"{'DATASET':<30} {'LOCAL':>8} {'L_GiB':>8} {'MINIO':>8} {'M_GiB':>8} {'M_LOC':>6} {'M_MIO':>6} {'WSZ':>6}")
for item in datasets_report:
    print(
        f"{item['dataset']:<30} "
        f"{item['local_files']:>8} "
        f"{(item['local_gib'] or 0):>8} "
        f"{item['minio_objects']:>8} "
        f"{(item['minio_gib'] or 0):>8} "
        f"{len(item['missing_local']):>6} "
        f"{len(item['missing_minio']):>6} "
        f"{len(item['wrong_size']):>6}"
    )

if not minio_ready:
    print()
    print("NOTE: MinIO 未启动或不可达，本次只校验了 local + manifest。")
PY
