#!/usr/bin/env bash
set -euo pipefail

# v1.5 存储压力检查（read-only）。
#
# 用途：
#   在跑 30GB 级数据 ETL / benchmark 之前评估磁盘水位。
#   - 打印 lsblk / df -h / findmnt
#   - 汇总 /data/robot-dh 各一级目录占用
#   - 汇总 MinIO 各 bucket 占用与对象数
#   - 检查 /dev/vdb 是否存在 / 是否挂载 / 是否有文件系统
#   - 估算剩余可处理数据规模
#
# 安全约束：
#   - 不 mkfs / 不 mount / 不修改 fstab
#   - 不修改 / 删除任何数据
#   - 即便 /dev/vdb 未挂载，也只打印建议
#
# 用法：
#   ./scripts/25_storage_pressure_report.sh
#
# 退出码：
#   0 - 正常生成报告
#   非 0 - 必须工具缺失 / .env 缺失 / Docker 异常

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
ENV_FILE="$PROJECT_DIR/.env"
LOG_ROOT="/data/robot-dh/logs"
TIMESTAMP=$(date -u +%Y%m%d_%H%M%S)
OUT_FILE="$LOG_ROOT/storage_pressure_${TIMESTAMP}.json"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE not found. Run ./scripts/03_generate_env.sh first." >&2
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker is not installed." >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 is required to render JSON / summary." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

mkdir -p "$LOG_ROOT"

TMP_DIR=$(mktemp -d)
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

LSBLK_JSON="$TMP_DIR/lsblk.json"
LSBLK_TXT="$TMP_DIR/lsblk.txt"
DF_JSON="$TMP_DIR/df.json"
DF_TXT="$TMP_DIR/df.txt"
FINDMNT_TXT="$TMP_DIR/findmnt.txt"
DU_TXT="$TMP_DIR/du.txt"
VDB_INFO="$TMP_DIR/vdb.json"
MINIO_BUCKETS_JSON="$TMP_DIR/minio_buckets.json"

# 优先用 JSON 输出，文本输出保留作为 fallback。
lsblk -b -O -J 2>/dev/null > "$LSBLK_JSON" || echo '{}' > "$LSBLK_JSON"
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT 2>/dev/null > "$LSBLK_TXT" || true

if df --output=source,fstype,size,used,avail,pcent,target -B1 2>/dev/null | tail -n +2 > "$DF_TXT"; then
  :
else
  df -B1 2>/dev/null > "$DF_TXT" || true
fi

findmnt -A -o TARGET,SOURCE,FSTYPE,OPTIONS 2>/dev/null > "$FINDMNT_TXT" || true

# /data/robot-dh 各一级目录占用（不递归到第二层，避免开销）。
if [[ -d /data/robot-dh ]]; then
  if sudo -n true >/dev/null 2>&1; then
    sudo -n du -sb /data/robot-dh/* 2>/dev/null > "$DU_TXT" || true
  else
    du -sb /data/robot-dh/* 2>/dev/null > "$DU_TXT" || true
  fi
else
  : > "$DU_TXT"
fi

# /dev/vdb 探测：是否存在 / 是否挂载 / blkid 是否有 fs。
python3 - "$LSBLK_JSON" "$VDB_INFO" <<'PY'
import json, os, sys, subprocess

lsblk_path, out_path = sys.argv[1], sys.argv[2]

info = {
    "exists": os.path.exists("/dev/vdb"),
    "mounted": False,
    "mountpoint": None,
    "fstype": None,
    "size_bytes": None,
    "children": [],
}

try:
    with open(lsblk_path, "r", encoding="utf-8") as f:
        lsblk = json.load(f)
except Exception:
    lsblk = {}

for blk in lsblk.get("blockdevices", []) or []:
    name = blk.get("name") or blk.get("kname")
    if name != "vdb":
        continue
    info["exists"] = True
    info["size_bytes"] = blk.get("size")
    info["fstype"] = blk.get("fstype")
    if blk.get("mountpoint"):
        info["mounted"] = True
        info["mountpoint"] = blk["mountpoint"]
    for child in blk.get("children", []) or []:
        info["children"].append({
            "name": child.get("name"),
            "fstype": child.get("fstype"),
            "size_bytes": child.get("size"),
            "mountpoint": child.get("mountpoint"),
        })
        if child.get("mountpoint"):
            info["mounted"] = True
            info["mountpoint"] = info["mountpoint"] or child["mountpoint"]

# blkid fallback：lsblk 看不到时，再尝试探测文件系统标识。
if info["exists"] and not info["fstype"]:
    try:
        r = subprocess.run(["blkid", "-o", "value", "-s", "TYPE", "/dev/vdb"],
                           capture_output=True, text=True, timeout=5)
        if r.returncode == 0:
            v = r.stdout.strip()
            if v:
                info["fstype"] = v
    except Exception:
        pass

with open(out_path, "w", encoding="utf-8") as f:
    json.dump(info, f, ensure_ascii=False, indent=2)
PY

# MinIO bucket 大小 / 对象数。容器没起来时优雅退化。
if docker inspect robot-dh-minio >/dev/null 2>&1; then
  if docker run --rm \
      --entrypoint sh \
      --network robot-dh-net \
      -e MINIO_ROOT_USER="$MINIO_ROOT_USER" \
      -e MINIO_ROOT_PASSWORD="$MINIO_ROOT_PASSWORD" \
      minio/mc:latest \
      -c "set -eu
mc alias set local http://robot-dh-minio:9000 \"\$MINIO_ROOT_USER\" \"\$MINIO_ROOT_PASSWORD\" >/dev/null
mc ls --json local | head -n 200" > "$TMP_DIR/buckets_list.jsonl" 2>/dev/null; then
    python3 - "$TMP_DIR/buckets_list.jsonl" "$MINIO_BUCKETS_JSON" <<'PY'
import json, sys, subprocess, shlex, os

src, out = sys.argv[1], sys.argv[2]
buckets = []
with open(src, "r", encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        if row.get("status") != "success":
            continue
        name = row.get("key") or row.get("name") or ""
        name = name.rstrip("/")
        if name:
            buckets.append(name)
buckets = sorted(set(buckets))

result = []
for bucket in buckets:
    cmd = (
        "set -eu; "
        "mc alias set local http://robot-dh-minio:9000 \"$MINIO_ROOT_USER\" \"$MINIO_ROOT_PASSWORD\" >/dev/null; "
        f"mc du --recursive --json local/{shlex.quote(bucket)}"
    )
    docker_cmd = [
        "docker", "run", "--rm",
        "--entrypoint", "sh",
        "--network", "robot-dh-net",
        "-e", "MINIO_ROOT_USER",
        "-e", "MINIO_ROOT_PASSWORD",
        "minio/mc:latest",
        "-c", cmd,
    ]
    env = os.environ.copy()
    env["MINIO_ROOT_USER"] = os.environ.get("MINIO_ROOT_USER", "")
    env["MINIO_ROOT_PASSWORD"] = os.environ.get("MINIO_ROOT_PASSWORD", "")
    try:
        r = subprocess.run(docker_cmd, capture_output=True, text=True, timeout=120, env=env)
    except Exception as e:
        result.append({"bucket": bucket, "error": str(e)})
        continue
    if r.returncode != 0:
        result.append({"bucket": bucket, "error": r.stderr.strip()[:200]})
        continue
    total_size, total_objs = 0, 0
    for line in r.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        # mc du 在不同版本字段不一样，统一兜底。
        s = row.get("size") or row.get("totalSize") or 0
        o = row.get("objects") or row.get("objectCount") or 0
        try:
            total_size = max(total_size, int(s))
            total_objs = max(total_objs, int(o))
        except (TypeError, ValueError):
            pass
    result.append({"bucket": bucket, "size_bytes": total_size, "object_count": total_objs})

with open(out, "w", encoding="utf-8") as f:
    json.dump(result, f, ensure_ascii=False, indent=2)
PY
  else
    echo '[]' > "$MINIO_BUCKETS_JSON"
  fi
else
  echo '[]' > "$MINIO_BUCKETS_JSON"
fi

# 汇总写报告 + 终端 summary。
python3 - "$LSBLK_TXT" "$DF_TXT" "$FINDMNT_TXT" "$DU_TXT" "$VDB_INFO" "$MINIO_BUCKETS_JSON" "$OUT_FILE" <<'PY'
import json, os, sys
from datetime import datetime, timezone

(lsblk_txt, df_txt, findmnt_txt, du_txt, vdb_info_path,
 minio_buckets_path, out_path) = sys.argv[1:]

def read_text(p: str) -> str:
    try:
        with open(p, "r", encoding="utf-8") as f:
            return f.read()
    except FileNotFoundError:
        return ""

def gib(n):
    try:
        return round(int(n) / 1024 / 1024 / 1024, 3)
    except (TypeError, ValueError):
        return None

with open(vdb_info_path, "r", encoding="utf-8") as f:
    vdb_info = json.load(f)
with open(minio_buckets_path, "r", encoding="utf-8") as f:
    minio_buckets = json.load(f)

# 解析 df，挑出 / 和 /data 所在的挂载点。
root_fs = {}
data_fs = {}
df_rows = []
for line in read_text(df_txt).splitlines():
    parts = line.split()
    if len(parts) < 6:
        continue
    # 跳过表头
    if parts[0].lower() in {"filesystem", "source"}:
        continue
    row = {
        "source": parts[0],
        "target": parts[-1],
    }
    # df --output=source,fstype,size,used,avail,pcent,target
    if len(parts) >= 7:
        try:
            row["fstype"] = parts[1]
            row["size_bytes"] = int(parts[2])
            row["used_bytes"] = int(parts[3])
            row["avail_bytes"] = int(parts[4])
            row["use_percent"] = parts[5]
        except ValueError:
            pass
    df_rows.append(row)
    if row["target"] == "/":
        root_fs = row
    if row["target"].startswith("/data") and not data_fs:
        data_fs = row

# /data/robot-dh 一级目录占用
du_entries = []
for line in read_text(du_txt).splitlines():
    parts = line.split("\t")
    if len(parts) != 2:
        parts = line.split()
        if len(parts) < 2:
            continue
    try:
        size = int(parts[0])
    except ValueError:
        continue
    du_entries.append({"path": parts[1], "size_bytes": size, "size_gib": gib(size)})

# MinIO 总占用
minio_total_bytes = sum(b.get("size_bytes") or 0 for b in minio_buckets)

# 估算剩余可处理数据规模
root_avail = root_fs.get("avail_bytes")
estimate = {}
if root_avail is not None:
    # 经验：再跑 30GB ETL，本地 raw + minio + tmp 大致按 3 倍预留
    estimate = {
        "root_avail_bytes": root_avail,
        "root_avail_gib": gib(root_avail),
        "reserved_for_etl_gib": 30,
        "estimated_room_for_new_30gb_run": root_avail >= 90 * 1024 ** 3,
        "estimated_room_for_15gb_run": root_avail >= 45 * 1024 ** 3,
        "headroom_factor_assumed": 3.0,
        "headroom_note": "raw 落盘 + MinIO 后端 + tmp/缓存约 3x 数据量，按 30GiB ETL 评估",
    }

warnings = []
if root_avail is not None and root_avail < 30 * 1024 ** 3:
    warnings.append(
        f"WARNING: root filesystem available {gib(root_avail)} GiB < 30 GiB，"
        "不建议继续跑 30GB 级 ETL，请先释放空间或挂载 /dev/vdb"
    )
if vdb_info.get("exists") and not vdb_info.get("mounted"):
    warnings.append(
        "INFO: /dev/vdb 存在但未挂载。可执行 ./scripts/26_plan_vdb_migration.sh 生成迁移计划；"
        "禁止本脚本自动 mkfs / mount"
    )

report = {
    "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "host": {
        "lsblk_text": read_text(lsblk_txt),
        "findmnt_text": read_text(findmnt_txt),
    },
    "filesystems": df_rows,
    "root_filesystem": root_fs,
    "data_filesystem": data_fs,
    "data_robot_dh_breakdown": du_entries,
    "vdb": vdb_info,
    "minio_buckets": minio_buckets,
    "minio_total_bytes": minio_total_bytes,
    "minio_total_gib": gib(minio_total_bytes),
    "capacity_estimate": estimate,
    "warnings": warnings,
}

with open(out_path, "w", encoding="utf-8") as f:
    json.dump(report, f, ensure_ascii=False, indent=2)

# Terminal-friendly summary
def line(s=""):
    print(s)

line("=" * 78)
line("v1.5 Storage Pressure Report")
line(f"generated_at: {report['generated_at']}")
line("=" * 78)
line()
line("-- Block devices (lsblk) --")
line(report["host"]["lsblk_text"].rstrip())
line()
line("-- Mounted filesystems (df) --")
line(f"{'TARGET':<32} {'FSTYPE':<10} {'SIZE_GiB':>10} {'USED_GiB':>10} {'AVAIL_GiB':>10} {'USE%':>6}")
for row in df_rows:
    line(
        f"{row.get('target','?'):<32} "
        f"{row.get('fstype','-'):<10} "
        f"{(gib(row.get('size_bytes')) or '-'):>10} "
        f"{(gib(row.get('used_bytes')) or '-'):>10} "
        f"{(gib(row.get('avail_bytes')) or '-'):>10} "
        f"{row.get('use_percent','-'):>6}"
    )
line()
line("-- /data/robot-dh top-level usage --")
if du_entries:
    for e in sorted(du_entries, key=lambda x: -x["size_bytes"]):
        line(f"  {e['size_gib']:>10} GiB  {e['path']}")
else:
    line("  (no entries)")
line()
line("-- MinIO buckets --")
if minio_buckets:
    line(f"{'BUCKET':<30} {'SIZE_GiB':>10} {'OBJECTS':>10}")
    for b in minio_buckets:
        line(f"{b.get('bucket','?'):<30} {(gib(b.get('size_bytes')) or '-'):>10} {b.get('object_count','-'):>10}")
    line(f"{'TOTAL':<30} {(gib(minio_total_bytes) or '-'):>10}")
else:
    line("  (MinIO 容器未启动或无法访问；已跳过)")
line()
line("-- /dev/vdb --")
line(f"  exists:    {vdb_info.get('exists')}")
line(f"  mounted:   {vdb_info.get('mounted')}")
line(f"  fstype:    {vdb_info.get('fstype')}")
line(f"  mountpoint:{vdb_info.get('mountpoint')}")
line(f"  size_GiB:  {gib(vdb_info.get('size_bytes'))}")
line()
line("-- Capacity estimate --")
for k, v in estimate.items():
    line(f"  {k}: {v}")
line()
line("-- Warnings --")
if warnings:
    for w in warnings:
        line(f"  {w}")
else:
    line("  (none)")
line()
line(f"JSON report written to: {out_path}")
PY

echo
echo "Storage pressure report finished. Report: $OUT_FILE"
