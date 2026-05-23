#!/usr/bin/env bash
set -euo pipefail

# 应用 v1.5 etl_shards 对齐迁移（003），把已有环境的 etl_shards 升级到主项目 SQLAlchemy 模型。
# 用法：
#   ./scripts/33_pg_apply_etl_shards_align.sh
# 前置条件：
#   - .env 已生成（含 POSTGRES_USER / POSTGRES_PASSWORD / POSTGRES_DB / ROBOT_DH_APP_USER）
#   - PostgreSQL 容器 robot-dh-postgres 已启动
# 行为：
#   - 用 POSTGRES_USER（admin）账号在容器内 psql 执行 003 迁移
#   - 通过 PGOPTIONS 把 robot_dh.app_user 注入为 GUC，迁移末尾的 DO 块会自动给应用账号 GRANT
#   - 幂等：列类型与列存在均按"已对齐则跳过"处理

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
ENV_FILE="$PROJECT_DIR/.env"
MIGRATION_FILE="$PROJECT_DIR/postgres/migrations/003_v1_5_etl_shards_align.sql"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE not found. Run ./scripts/03_generate_env.sh first." >&2
  exit 1
fi

if [[ ! -f "$MIGRATION_FILE" ]]; then
  echo "ERROR: Migration file not found: $MIGRATION_FILE" >&2
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker is not installed." >&2
  exit 1
fi

if ! docker inspect robot-dh-postgres >/dev/null 2>&1; then
  echo "ERROR: PostgreSQL container robot-dh-postgres is not available. Run ./scripts/04_up.sh first." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

: "${POSTGRES_USER:?POSTGRES_USER not set in .env}"
: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD not set in .env}"
: "${POSTGRES_DB:?POSTGRES_DB not set in .env}"
: "${ROBOT_DH_APP_USER:?ROBOT_DH_APP_USER not set in .env}"

# 通过 PGOPTIONS 把 app_user 注入为 GUC，让 DO 块自动 GRANT 给应用账号。
docker exec -i \
  -e PGPASSWORD="$POSTGRES_PASSWORD" \
  -e PGOPTIONS="-c robot_dh.app_user=$ROBOT_DH_APP_USER" \
  robot-dh-postgres \
  psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -P pager=off -f - < "$MIGRATION_FILE"

echo "Applied PostgreSQL etl_shards alignment migration from $MIGRATION_FILE"
