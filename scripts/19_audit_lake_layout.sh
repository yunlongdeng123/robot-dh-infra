#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
ENV_FILE="$PROJECT_DIR/.env"
STATUS=0

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE not found. Run ./scripts/03_generate_env.sh first." >&2
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

ROBOT_DH_LAKE_BUCKET="${ROBOT_DH_LAKE_BUCKET:-robot-lake}"

run_check() {
  local label="$1"
  shift
  echo "== $label =="
  if "$@"; then
    :
  else
    STATUS=1
  fi
  echo
}

run_mc() {
  local script="$1"

  docker run --rm \
    --entrypoint sh \
    --network robot-dh-net \
    -e MINIO_ROOT_USER="$MINIO_ROOT_USER" \
    -e MINIO_ROOT_PASSWORD="$MINIO_ROOT_PASSWORD" \
    -e ROBOT_DH_LAKE_BUCKET="$ROBOT_DH_LAKE_BUCKET" \
    minio/mc:latest \
    -c "$script"
}

run_psql() {
  local sql="$1"

  printf '%s\n' "$sql" | docker exec -i \
    -e PGPASSWORD="$POSTGRES_PASSWORD" \
    robot-dh-postgres \
    psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -P pager=off -f -
}

read -r -d '' MINIO_AUDIT_SCRIPT <<'EOF' || true
set -eu

attempt=1
while [ "$attempt" -le 30 ]; do
  if mc alias set local http://robot-dh-minio:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null 2>&1 && mc ready local >/dev/null 2>&1; then
    break
  fi
  if [ "$attempt" -eq 30 ]; then
    echo "ERROR: Could not reach MinIO at robot-dh-minio:9000." >&2
    exit 1
  fi
  sleep 2
  attempt=$((attempt + 1))
done

mc stat "local/$ROBOT_DH_LAKE_BUCKET" >/dev/null
echo "Bucket present: $ROBOT_DH_LAKE_BUCKET"

for marker in raw/.keep ods/.keep dwd/.keep ads/quality/.keep lineage/events/.keep tmp/.keep; do
  mc stat "local/$ROBOT_DH_LAKE_BUCKET/$marker" >/dev/null
  echo "Prefix marker present: $ROBOT_DH_LAKE_BUCKET/$marker"
done

echo
echo "Bucket versioning:"
mc version info "local/$ROBOT_DH_LAKE_BUCKET"
EOF

read -r -d '' PG_AUDIT_SQL <<'EOF' || true
DO $$
DECLARE
  missing_tables text;
BEGIN
  SELECT string_agg(name, ', ' ORDER BY name)
    INTO missing_tables
  FROM (VALUES
    ('dataset_versions'),
    ('etl_jobs'),
    ('lake_assets'),
    ('lineage_edges'),
    ('quality_snapshots')
  ) AS required(name)
  WHERE to_regclass('public.' || name) IS NULL;

  IF missing_tables IS NOT NULL THEN
    RAISE EXCEPTION 'Missing lake metadata tables: %', missing_tables;
  END IF;
END
$$;

SELECT name AS table_name, 'present' AS status
FROM (VALUES
  ('dataset_versions'),
  ('etl_jobs'),
  ('lake_assets'),
  ('lineage_edges'),
  ('quality_snapshots')
) AS required(name)
ORDER BY name;
EOF

run_shell_check() {
  local label="$1"
  local cmd="$2"
  echo "== $label =="
  if bash -lc "$cmd"; then
    :
  else
    STATUS=1
  fi
  echo
}

run_check "MinIO lake bucket / prefix audit" run_mc "$MINIO_AUDIT_SCRIPT"
run_check "PostgreSQL lake metadata tables" run_psql "$PG_AUDIT_SQL"
run_check "Disk usage: df -h /data/robot-dh" df -h /data/robot-dh
run_shell_check "Disk usage: du -sh /data/robot-dh/*" "shopt -s nullglob; entries=(/data/robot-dh/*); if (( \${#entries[@]} )); then if sudo -n true >/dev/null 2>&1; then sudo -n du -sh \"\${entries[@]}\"; else du -sh \"\${entries[@]}\" 2>/dev/null || true; fi; else echo 'No entries under /data/robot-dh yet.'; fi"

exit "$STATUS"
