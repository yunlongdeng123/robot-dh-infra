#!/usr/bin/env bash
set -euo pipefail

# v1.6 临时目录 lifecycle 审计。
#
# 默认 read-only：
#   - 扫描 robot-lake/tmp/、robot-dh-artifacts/tmp/、workflow tmp prefix
#   - 输出对象数、总大小、最老对象时间
#   - 落 Markdown 报告 + 终端 summary
#
# --apply-cleanup：
#   - 必须交互输入 APPLY_TMP_CLEANUP 才执行
#   - 仅删除 mtime > 7 天 的 tmp 对象（mc rm --older-than 7d --recursive）
#   - 严格限定到 tmp/ prefix；任何对 raw / ods / dwd / ads 的引用都会拒绝
#
# 安全约束：
#   - 不动 raw / ods / dwd / ads / lineage / manifests / runs
#   - 不修改 lifecycle rule（lifecycle rule 由 scripts/28_minio_lifecycle_plan.sh 管理）

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
ENV_FILE="$PROJECT_DIR/.env"
LOG_ROOT="/data/robot-dh/logs"
TIMESTAMP=$(date -u +%Y%m%d_%H%M%S)
OUT_FILE="$LOG_ROOT/v1_6_storage_tmp_lifecycle_${TIMESTAMP}.md"

APPLY_CLEANUP=0
CLEANUP_DAYS=7
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply-cleanup) APPLY_CLEANUP=1 ;;
    --days)
      shift
      [[ $# -gt 0 ]] || { echo "ERROR: --days 需要一个数字参数" >&2; exit 1; }
      CLEANUP_DAYS="$1"
      ;;
    -h|--help)
      cat <<EOF >&2
Usage: $0 [--apply-cleanup] [--days N]

默认 read-only。--apply-cleanup 需交互输入 APPLY_TMP_CLEANUP；仅清理 mtime > N 天的 tmp 对象，默认 7。
EOF
      exit 0
      ;;
    *) echo "ERROR: unknown arg: $1" >&2; exit 1 ;;
  esac
  shift
done

if [[ ! "$CLEANUP_DAYS" =~ ^[0-9]+$ ]] || (( CLEANUP_DAYS < 1 )); then
  echo "ERROR: --days 必须是 >=1 的整数" >&2
  exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE not found." >&2
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker is not installed." >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 is required to render summary." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

ROBOT_DH_ARTIFACT_BUCKET="${ROBOT_DH_ARTIFACT_BUCKET:-robot-dh-artifacts}"
ROBOT_DH_LAKE_BUCKET="${ROBOT_DH_LAKE_BUCKET:-robot-lake}"

# 允许审计的 prefix 白名单。任何 raw / ods / dwd / ads / lineage / manifests / runs 路径
# 都禁止出现在这个列表里；新增条目时必须人工 review。
# 形式：bucket=relative_prefix
PREFIXES=(
  "${ROBOT_DH_LAKE_BUCKET}=tmp/"
  "${ROBOT_DH_ARTIFACT_BUCKET}=tmp/"
  "${ROBOT_DH_LAKE_BUCKET}=tmp/workflows/"
  "${ROBOT_DH_ARTIFACT_BUCKET}=tmp/workflows/"
)

# 防御性二次校验：禁止非 tmp 入口
for entry in "${PREFIXES[@]}"; do
  bucket="${entry%%=*}"
  prefix="${entry#*=}"
  case "$prefix" in
    tmp|tmp/*) ;;
    *)
      echo "FATAL: PREFIXES 中出现非 tmp 入口 ${entry}；本脚本只允许处理 tmp，立即终止。" >&2
      exit 1
      ;;
  esac
  case "$prefix" in
    *raw*|*ods*|*dwd*|*ads*|*lineage*|*manifests*|*runs/*|/raw*|/ods*|/dwd*|/ads*)
      echo "FATAL: PREFIXES 中出现非 tmp 词元（${entry}），立即终止。" >&2
      exit 1
      ;;
  esac
done

mkdir -p "$LOG_ROOT"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

mc_run() {
  docker run --rm \
    --network robot-dh-net \
    -e "MC_HOST_local=http://${MINIO_ROOT_USER}:${MINIO_ROOT_PASSWORD}@robot-dh-minio:9000" \
    minio/mc:latest \
    "$@"
}

if ! docker inspect robot-dh-minio >/dev/null 2>&1; then
  echo "ERROR: MinIO container robot-dh-minio is not available." >&2
  exit 1
fi

: > "$OUT_FILE"
write_md() { printf '%s\n' "${1:-}" >> "$OUT_FILE"; }

write_md "# v1.6 Storage tmp Lifecycle Audit"
write_md
write_md "- generated_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
write_md "- mode: $([[ $APPLY_CLEANUP -eq 1 ]] && echo APPLY_CLEANUP || echo READ_ONLY)"
write_md "- cleanup_threshold_days: ${CLEANUP_DAYS}"
write_md "- 白名单 prefix（仅允许 tmp/）："
for entry in "${PREFIXES[@]}"; do
  write_md "  - \`${entry%%=*}/${entry#*=}\`"
done
write_md

# 1) 收集每个 prefix 的对象列表（mc ls --recursive --json，不 download object 本身）
write_md "## 1. tmp prefix 统计"
write_md
write_md "| bucket | prefix | object_count | total_size_gib | oldest_object_utc |"
write_md "|--------|--------|--------------|----------------|-------------------|"

declare -A STATS_COUNT
declare -A STATS_BYTES
declare -A STATS_OLDEST

for entry in "${PREFIXES[@]}"; do
  bucket="${entry%%=*}"
  prefix="${entry#*=}"
  raw="$TMP_DIR/${bucket}_${prefix//\//_}.jsonl"
  if mc_run ls --recursive --json "local/${bucket}/${prefix}" > "$raw" 2>/dev/null; then
    :
  else
    : > "$raw"
  fi

  read -r cnt bytes oldest < <(python3 - "$raw" <<'PY'
import json, sys
src = sys.argv[1]
cnt = 0
total = 0
oldest = ""
with open(src, "r", encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        if row.get("type") not in (None, "file"):
            # 跳过 directory 行
            if row.get("type") == "folder":
                continue
        size = row.get("size") or 0
        try:
            total += int(size)
        except (TypeError, ValueError):
            pass
        cnt += 1
        ts = row.get("lastModified") or row.get("last_modified") or ""
        if ts and (not oldest or ts < oldest):
            oldest = ts
print(f"{cnt} {total} {oldest or '-'}")
PY
)
  STATS_COUNT["$entry"]="$cnt"
  STATS_BYTES["$entry"]="$bytes"
  STATS_OLDEST["$entry"]="$oldest"

  gib=$(python3 -c "print(round(${bytes:-0}/1024/1024/1024, 3))")
  write_md "| ${bucket} | ${prefix} | ${cnt} | ${gib} | ${oldest} |"
done
write_md

# 2) 终端 summary
echo "v1.6 tmp lifecycle audit -> $OUT_FILE"
echo
echo "Mode: $([[ $APPLY_CLEANUP -eq 1 ]] && echo APPLY_CLEANUP || echo READ_ONLY)"
echo
printf '%-30s %-25s %12s %15s %s\n' BUCKET PREFIX OBJECTS SIZE_GiB OLDEST_UTC
for entry in "${PREFIXES[@]}"; do
  bucket="${entry%%=*}"
  prefix="${entry#*=}"
  cnt="${STATS_COUNT[$entry]:-0}"
  bytes="${STATS_BYTES[$entry]:-0}"
  oldest="${STATS_OLDEST[$entry]:-}"
  gib=$(python3 -c "print(round(${bytes:-0}/1024/1024/1024, 3))")
  printf '%-30s %-25s %12s %15s %s\n' "$bucket" "$prefix" "$cnt" "$gib" "${oldest:--}"
done

# 3) 如果不是 apply-cleanup，到此结束
if [[ $APPLY_CLEANUP -ne 1 ]]; then
  echo
  echo "Read-only audit done. Markdown: $OUT_FILE"
  echo "如需清理，请加 --apply-cleanup（仍只动 tmp，需要交互确认）。"
  exit 0
fi

# 4) APPLY_CLEANUP 模式：必须输入 APPLY_TMP_CLEANUP 才允许执行
echo
echo "你即将执行 tmp 清理（仅 tmp，不动 raw/ods/dwd/ads）：" >&2
for entry in "${PREFIXES[@]}"; do
  echo "  - local/${entry%%=*}/${entry#*=}  (older than ${CLEANUP_DAYS}d)" >&2
done
echo "请输入 APPLY_TMP_CLEANUP 以确认（其他任意输入将取消）：" >&2
read -r CONFIRM
if [[ "$CONFIRM" != "APPLY_TMP_CLEANUP" ]]; then
  echo "未确认，取消。" >&2
  exit 1
fi

write_md "## 2. 清理执行结果"
write_md
write_md "| bucket | prefix | removed_count | freed_size_gib | error |"
write_md "|--------|--------|---------------|----------------|-------|"

for entry in "${PREFIXES[@]}"; do
  bucket="${entry%%=*}"
  prefix="${entry#*=}"
  # 再次防御：拒绝任何非 tmp 路径
  case "$prefix" in
    tmp|tmp/*) ;;
    *)
      echo "FATAL: 非 tmp prefix 出现在 APPLY 阶段 (${entry})，立即终止。" >&2
      exit 1
      ;;
  esac

  out_log="$TMP_DIR/rm_${bucket}_${prefix//\//_}.log"
  err=""
  if mc_run rm --recursive --force \
        --older-than "${CLEANUP_DAYS}d" \
        "local/${bucket}/${prefix}" > "$out_log" 2>&1; then
    :
  else
    err=$(tail -n 1 "$out_log" || true)
  fi

  # 解析 mc rm 输出统计
  read -r removed_cnt removed_bytes < <(python3 - "$out_log" <<'PY'
import re, sys
src = sys.argv[1]
cnt = 0
bytes_ = 0
with open(src, "r", encoding="utf-8", errors="replace") as f:
    for line in f:
        if "Removing" in line or "Removed" in line or "removed" in line:
            cnt += 1
print(f"{cnt} {bytes_}")
PY
)
  gib=$(python3 -c "print(round(${removed_bytes:-0}/1024/1024/1024, 3))")
  write_md "| ${bucket} | ${prefix} | ${removed_cnt} | ${gib} | ${err//|/\\|} |"
  echo "  cleaned local/${bucket}/${prefix}: removed=${removed_cnt}"
done

echo
echo "Cleanup done. Markdown: $OUT_FILE"
