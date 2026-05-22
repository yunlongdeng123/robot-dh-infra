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

if ! docker compose version >/dev/null 2>&1; then
  echo "ERROR: docker compose plugin is not available." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

cd "$PROJECT_DIR"

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

run_check "docker compose ps" docker compose ps
run_shell_check "postgres pg_isready" "docker exec robot-dh-postgres sh -c 'pg_isready -U \"\$POSTGRES_USER\" -d \"\$POSTGRES_DB\"'"
run_shell_check "postgres version" "docker exec robot-dh-postgres sh -c 'psql -U \"\$POSTGRES_USER\" -d \"\$POSTGRES_DB\" -Atqc \"SELECT version();\"'"
run_shell_check "redis PING" "docker exec robot-dh-redis sh -c 'redis-cli -a \"\$REDIS_PASSWORD\" ping'"
run_shell_check "minio health" "curl -fsS http://127.0.0.1:9000/minio/health/live >/dev/null"
run_shell_check "minio bucket list" "docker run --rm --entrypoint sh --network robot-dh-net -e MINIO_ROOT_USER=\"$MINIO_ROOT_USER\" -e MINIO_ROOT_PASSWORD=\"$MINIO_ROOT_PASSWORD\" minio/mc:latest -c 'mc alias set local http://robot-dh-minio:9000 \"\$MINIO_ROOT_USER\" \"\$MINIO_ROOT_PASSWORD\" >/dev/null && mc ls local'"
run_check "df -h /data/robot-dh" df -h /data/robot-dh
run_shell_check "du -sh /data/robot-dh/*" "shopt -s nullglob; entries=(/data/robot-dh/*); if (( \${#entries[@]} )); then if sudo -n true >/dev/null 2>&1; then sudo -n du -sh \"\${entries[@]}\"; else du -sh \"\${entries[@]}\"; fi; else echo 'No entries under /data/robot-dh yet.'; fi"

exit "$STATUS"