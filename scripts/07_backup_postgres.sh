#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
ENV_FILE="$PROJECT_DIR/.env"
BACKUP_DIR="/data/robot-dh/postgres/backups"
TIMESTAMP=$(date -u +%Y%m%d_%H%M%S)
BACKUP_FILE="$BACKUP_DIR/robot_dh_${TIMESTAMP}.dump"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE not found. Run ./scripts/03_generate_env.sh first." >&2
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker is not installed." >&2
  exit 1
fi

mkdir -p "$BACKUP_DIR"

echo "Creating PostgreSQL backup at $BACKUP_FILE"
if docker exec robot-dh-postgres sh -c 'export PGPASSWORD="$POSTGRES_PASSWORD"; pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc' > "$BACKUP_FILE"; then
  chmod 600 "$BACKUP_FILE"
else
  rm -f "$BACKUP_FILE"
  echo "ERROR: PostgreSQL backup failed." >&2
  exit 1
fi

declare -A keep_files=()
mapfile -t latest_twenty < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'robot_dh_*.dump' | sort -r | head -n 20)
for file_path in "${latest_twenty[@]}"; do
  keep_files["$file_path"]=1
done

pruned_count=0
while IFS= read -r old_file; do
  if [[ -z "$old_file" ]]; then
    continue
  fi
  if [[ -z "${keep_files[$old_file]+x}" ]]; then
    rm -f "$old_file"
    pruned_count=$((pruned_count + 1))
  fi
done < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'robot_dh_*.dump' -mtime +7 | sort -r)

echo "PostgreSQL backup completed: $BACKUP_FILE"
echo "Pruned old PostgreSQL backups: $pruned_count"