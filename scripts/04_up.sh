#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
ENV_FILE="$PROJECT_DIR/.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE not found. Run ./scripts/03_generate_env.sh first." >&2
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker is not installed. Run ./scripts/02_install_docker.sh first." >&2
  exit 1
fi

if ! docker compose version >/dev/null 2>&1; then
  echo "ERROR: docker compose plugin is not available. Run ./scripts/02_install_docker.sh first." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

for required_dir in /data/robot-dh/postgres/data /data/robot-dh/minio/data /data/robot-dh/redis/data; do
  if [[ ! -d "$required_dir" ]]; then
    echo "ERROR: Missing data directory: $required_dir" >&2
    echo "Run ./scripts/01_prepare_dirs.sh before bringing the stack up." >&2
    exit 1
  fi
done

cd "$PROJECT_DIR"
docker compose up -d --remove-orphans

docker exec robot-dh-postgres sh -c '/docker-entrypoint-initdb.d/02_sync_pg_hba.sh'

if docker exec robot-dh-postgres sh -c 'psql -U "$POSTGRES_USER" -d postgres -Atqc "SELECT 1 FROM pg_database WHERE datname = '\''$POSTGRES_DB'\'';"' | grep -q 1; then
  echo "PostgreSQL application database already exists."
else
  echo "PostgreSQL application database is missing; running bootstrap script inside the existing container."
  docker exec robot-dh-postgres sh -c '/docker-entrypoint-initdb.d/01_init_robot_dh.sh'
fi

docker compose ps

echo "Stack startup command completed."