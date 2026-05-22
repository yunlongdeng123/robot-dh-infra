#!/usr/bin/env bash
set -euo pipefail

# 应用 v1.5 PostgreSQL schema：scale / benchmark / Argo workflow / runtime_events。
# 幂等：只做 CREATE IF NOT EXISTS，不 DROP / ALTER 现有列。

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
ENV_FILE="$PROJECT_DIR/.env"
MIGRATION_FILE="$PROJECT_DIR/postgres/migrations/002_v1_5_scale_benchmark.sql"

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

# 将 app user 通过 GUC 注入，让 migration 里的 DO 块自动给应用账号 GRANT。
docker exec -i \
  -e PGPASSWORD="$POSTGRES_PASSWORD" \
  -e PGOPTIONS="-c robot_dh.app_user=$ROBOT_DH_APP_USER" \
  robot-dh-postgres \
  psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -P pager=off -f - < "$MIGRATION_FILE"

echo "Applied PostgreSQL v1.5 schema from $MIGRATION_FILE"
