#!/usr/bin/env bash
set -euo pipefail

# v1.5 MinIO 生命周期 / 成本计划。
#
# 默认 dry-run：打印每个 bucket 的占用、对象数、versioning 状态、当前 ILM 规则、
# 以及推荐的 lifecycle 建议（不会应用任何变更）。
#
# 仅当传 --apply 且交互输入 APPLY_LIFECYCLE 时，才会真正给
#   robot-lake/tmp/        7 天过期
#   robot-dh-artifacts/tmp/ 7 天过期
# 应用 lifecycle rule。其他 bucket / prefix 一律不动。
#
# 用法：
#   ./scripts/28_minio_lifecycle_plan.sh              # 只打印计划
#   ./scripts/28_minio_lifecycle_plan.sh --apply      # 交互确认后写入 tmp 规则

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
ENV_FILE="$PROJECT_DIR/.env"

APPLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1 ;;
    -h|--help)
      echo "Usage: $0 [--apply]" >&2
      exit 0
      ;;
    *) echo "ERROR: unknown arg: $1" >&2; exit 1 ;;
  esac
  shift
done

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE not found." >&2
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker is not installed." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

ROBOT_DH_DATA_BUCKET="${ROBOT_DH_DATA_BUCKET:-robot-datasets}"
ROBOT_DH_ARTIFACT_BUCKET="${ROBOT_DH_ARTIFACT_BUCKET:-robot-dh-artifacts}"
ROBOT_DH_BACKUP_BUCKET="${ROBOT_DH_BACKUP_BUCKET:-robot-dh-backups}"
ROBOT_DH_LAKE_BUCKET="${ROBOT_DH_LAKE_BUCKET:-robot-lake}"

BUCKETS=(
  "$ROBOT_DH_DATA_BUCKET"
  "$ROBOT_DH_LAKE_BUCKET"
  "$ROBOT_DH_ARTIFACT_BUCKET"
  "$ROBOT_DH_BACKUP_BUCKET"
)

LOG_ROOT="/data/robot-dh/logs"
mkdir -p "$LOG_ROOT"
TIMESTAMP=$(date -u +%Y%m%d_%H%M%S)
OUT_FILE="$LOG_ROOT/minio_lifecycle_plan_${TIMESTAMP}.txt"

# minio/mc:latest 镜像是 distroless 风格，**只有 mc 二进制**，没有 sed / grep / awk。
# 所以容器内只调用 mc 子命令本身，所有过滤 / 缩进都放到 host bash 完成。
# 使用 MC_HOST_<alias> 环境变量直接注入连接配置，省掉 `mc alias set` 步骤。
mc_run() {
  docker run --rm \
    --network robot-dh-net \
    -e "MC_HOST_local=http://${MINIO_ROOT_USER}:${MINIO_ROOT_PASSWORD}@robot-dh-minio:9000" \
    minio/mc:latest \
    "$@"
}

indent2() {
  while IFS= read -r line; do
    printf '  %s\n' "$line"
  done
}

# bucket 状态收集（du / version / ilm export）
{
  echo "================================================================================"
  echo "MinIO Lifecycle Plan"
  echo "generated_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "mode:         $([[ $APPLY -eq 1 ]] && echo APPLY || echo DRY-RUN)"
  echo "================================================================================"
  echo
  for bucket in "${BUCKETS[@]}"; do
    echo "------------------------------------------------------------"
    echo "Bucket: $bucket"
    echo "------------------------------------------------------------"

    if ! mc_run stat "local/$bucket" >/dev/null 2>&1; then
      echo "  (bucket 不存在或不可达)"
      echo
      continue
    fi

    echo
    echo "  -- du --"
    # mc du --recursive 末行是合计；取末行后再缩进
    mc_run du --recursive "local/$bucket" 2>/dev/null | tail -n 1 | indent2 \
      || echo "  (mc du 调用失败)"

    echo
    echo "  -- version info --"
    mc_run version info "local/$bucket" 2>&1 | indent2 \
      || echo "  (mc version info 调用失败)"

    echo
    echo "  -- ilm rules (当前) --"
    # mc 在 bucket 没有 ILM 配置时会以非 0 退出并打印固定的错误串；这是正常状态而不是失败。
    ilm_out=$(mc_run ilm rule ls "local/$bucket" 2>&1 || true)
    if [[ "$ilm_out" == *"lifecycle configuration does not exist"* ]]; then
      echo "  (尚未配置 lifecycle 规则)"
    elif [[ -z "$ilm_out" ]]; then
      echo "  (空输出)"
    else
      printf '%s\n' "$ilm_out" | indent2
    fi

    echo
  done

  cat <<EOF

================================================================================
推荐 lifecycle / 成本建议（仅供 review，不自动应用）
================================================================================

bucket: $ROBOT_DH_DATA_BUCKET (raw 数据 / scale30)
  - prefix: raw/             保留：不设过期，由人工策划
  - prefix: manifests/       保留：不设过期，作为审计依据
  - 建议：不要为整 bucket 设 expire；如要清理冷数据，单独走人工 mc rm

bucket: $ROBOT_DH_LAKE_BUCKET (lake：raw/ods/dwd/ads/lineage/tmp)
  - prefix: tmp/             *** 建议 7 天 expire ***（本脚本 --apply 会写）
  - prefix: ods/ dwd/ ads/   保留：受 dataset_versions / lake_assets 管控
  - prefix: lineage/         保留：审计用途，建议 180 天后归档（人工）

bucket: $ROBOT_DH_ARTIFACT_BUCKET
  - prefix: runs/            建议 30 天 expire（quality gate 报告）
  - prefix: tmp/             *** 建议 7 天 expire ***（本脚本 --apply 会写）

bucket: $ROBOT_DH_BACKUP_BUCKET
  - 建议保留最近 20 个备份或 30 天，按时间排序删除
  - 由于备份属于关键数据，建议改用 retention policy 而不是 ILM
  - 本脚本不自动操作

versioning 注意：
  - 所有 bucket 已开启 versioning。lifecycle expire 默认只删除 current version，
    旧版本仍会被 NoncurrentVersionExpiration 控制。要回收磁盘，需追加
    NoncurrentVersionExpiration N day 规则。

================================================================================
EOF
} | tee "$OUT_FILE"

if [[ $APPLY -ne 1 ]]; then
  echo
  echo "Dry-run only. To apply tmp lifecycle rules, rerun with --apply."
  echo "Plan saved to: $OUT_FILE"
  exit 0
fi

echo
echo "你即将给以下 prefix 应用 ILM 规则：" >&2
echo "  - local/$ROBOT_DH_LAKE_BUCKET/tmp/       expire 7 天" >&2
echo "  - local/$ROBOT_DH_ARTIFACT_BUCKET/tmp/   expire 7 天" >&2
echo "请输入 APPLY_LIFECYCLE 确认（其他任意输入将取消）：" >&2
read -r CONFIRM
if [[ "$CONFIRM" != "APPLY_LIFECYCLE" ]]; then
  echo "未确认，取消。" >&2
  exit 1
fi

# 幂等判断：把现有 ilm rule 列表拉到 host，再用 bash 正则匹配。
# 容器内只跑 mc 命令本身，不依赖 sed / grep / awk。
apply_rule() {
  local bucket="$1"
  local prefix="$2"
  local days="$3"
  local listing
  listing=$(mc_run ilm rule ls "local/$bucket" 2>/dev/null || true)
  if [[ "$listing" == *"$prefix"*"Expiration"*"${days}d"* ]]; then
    echo "  [skip] local/$bucket/$prefix 已有 ${days}d 规则"
    return 0
  fi
  mc_run ilm rule add --prefix "$prefix" --expire-days "$days" "local/$bucket"
  echo "  [apply] local/$bucket/$prefix expire=${days}d"
}

apply_rule "$ROBOT_DH_LAKE_BUCKET" tmp/ 7
apply_rule "$ROBOT_DH_ARTIFACT_BUCKET" tmp/ 7

echo
echo 'After:'
mc_run ilm rule ls "local/$ROBOT_DH_LAKE_BUCKET" | indent2 || true
mc_run ilm rule ls "local/$ROBOT_DH_ARTIFACT_BUCKET" | indent2 || true

echo "Applied lifecycle rules. See $OUT_FILE for the pre-apply snapshot."
