#!/usr/bin/env bash
set -euo pipefail

# 应用 v1.6 PostgreSQL schema：robot platform metadata
#   qc_contracts / qc_contract_runs
#   workflow_runs / workflow_steps
#   asset_profiles
#   ml_ready_datasets
#   dataset_partitions
#   task_heartbeats
#   openlineage_events
#
# 行为：
#   - 用 POSTGRES_USER（管理员）账号执行 005 迁移
#   - migration 内显式给 robot_dh_app 执行 GRANT
#   - 全部 CREATE IF NOT EXISTS / DO 块判存，幂等，可重复执行
#   - 不 DROP，不 TRUNCATE，不删除已有数据
#
# 退出码：0 = OK，非 0 = 失败。

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
ENV_FILE="$PROJECT_DIR/.env"
MIGRATION_FILE="$PROJECT_DIR/postgres/migrations/005_v1_6_robot_platform.sql"

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
docker exec -i \
  -e PGPASSWORD="$POSTGRES_PASSWORD" \
  robot-dh-postgres \
  psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -P pager=off -f - < "$MIGRATION_FILE"

echo "Applied PostgreSQL v1.6 schema from $MIGRATION_FILE"
echo

# 应用后列出新增表（仅查询，不修改数据）
LIST_SQL=$(cat <<'EOF'
SELECT relname AS table_name,
       to_char(pg_relation_size(c.oid) / 1024.0, 'FM999990.00') AS size_kib
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = 'public'
   AND c.relkind = 'r'
   AND c.relname IN (
     'qc_contracts', 'qc_contract_runs',
     'workflow_runs', 'workflow_steps',
     'asset_profiles', 'ml_ready_datasets',
     'dataset_partitions', 'task_heartbeats',
     'openlineage_events'
   )
 ORDER BY relname;
EOF
)

echo "v1.6 tables (size in KiB):"
printf '%s\n' "$LIST_SQL" | docker exec -i \
  -e PGPASSWORD="$POSTGRES_PASSWORD" \
  robot-dh-postgres \
  psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -P pager=off -A -F'|' -f -
