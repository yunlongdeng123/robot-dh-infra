#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
ENV_FILE="$PROJECT_DIR/.env"
DROP_DB=0

usage() {
  echo "Usage: $0 <backup-file> [--drop-db]" >&2
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage
  exit 1
fi

BACKUP_FILE="$1"
if [[ ! -f "$BACKUP_FILE" ]]; then
  echo "ERROR: Backup file not found: $BACKUP_FILE" >&2
  exit 1
fi

if [[ $# -eq 2 ]]; then
  if [[ "$2" != "--drop-db" ]]; then
    usage
    exit 1
  fi
  DROP_DB=1
fi

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

echo "WARNING: PostgreSQL restore can overwrite existing schema objects and data."
echo "Target database: $POSTGRES_DB"
echo "Backup file: $BACKUP_FILE"
if [[ $DROP_DB -eq 1 ]]; then
  echo "Mode: recreate database before restore (--drop-db)"
else
  echo "Mode: restore into existing database with --clean --if-exists"
fi

read -r -p "Type RESTORE to continue: " restore_confirm
if [[ "$restore_confirm" != "RESTORE" ]]; then
  echo "Restore cancelled."
  exit 1
fi

if [[ $DROP_DB -eq 1 ]]; then
  read -r -p "Type DROP_DATABASE to confirm database recreation: " drop_confirm
  if [[ "$drop_confirm" != "DROP_DATABASE" ]]; then
    echo "Restore cancelled before dropping the database."
    exit 1
  fi

  docker exec -e TARGET_DB="$POSTGRES_DB" robot-dh-postgres sh -c 'export PGPASSWORD="$POSTGRES_PASSWORD"; psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d postgres -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='\''$TARGET_DB'\'' AND pid <> pg_backend_pid();" >/dev/null; dropdb --if-exists -U "$POSTGRES_USER" "$TARGET_DB"; createdb -U "$POSTGRES_USER" "$TARGET_DB"'

  docker exec -i robot-dh-postgres sh -c 'export PGPASSWORD="$POSTGRES_PASSWORD"; pg_restore --no-owner -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < "$BACKUP_FILE"
else
  docker exec -i robot-dh-postgres sh -c 'export PGPASSWORD="$POSTGRES_PASSWORD"; pg_restore --clean --if-exists --no-owner -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < "$BACKUP_FILE"
fi

echo "PostgreSQL restore completed."