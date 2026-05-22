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
  echo "ERROR: docker is not installed." >&2
  exit 1
fi

if ! docker inspect robot-dh-minio >/dev/null 2>&1; then
  echo "ERROR: MinIO container robot-dh-minio is not available. Run ./scripts/04_up.sh first." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

ROBOT_DH_LAKE_BUCKET="${ROBOT_DH_LAKE_BUCKET:-robot-lake}"

read -r -d '' MC_SCRIPT <<'EOF' || true
set -eu

attempt=1
while [ "$attempt" -le 20 ]; do
  if mc alias set client http://robot-dh-minio:9000 "$MINIO_APP_ACCESS_KEY" "$MINIO_APP_SECRET_KEY" >/dev/null 2>&1; then
    break
  fi
  if [ "$attempt" -eq 20 ]; then
    echo "ERROR: Could not connect to MinIO with the configured app credentials." >&2
    exit 1
  fi
  sleep 2
  attempt=$((attempt + 1))
done

mc stat "client/$ROBOT_DH_LAKE_BUCKET" >/dev/null

run_id="smoke_$(date -u +%Y%m%d_%H%M%S)_$$"
object_path="$ROBOT_DH_LAKE_BUCKET/tmp/$run_id/health.txt"

printf 'robot-dh lake smoke test\n' | mc pipe "client/$object_path" >/dev/null
mc stat "client/$object_path" >/dev/null
mc rm "client/$object_path" >/dev/null

echo "MinIO lake smoke test passed: s3://$object_path"
EOF

docker run --rm \
  --entrypoint sh \
  --network robot-dh-net \
  -e MINIO_APP_ACCESS_KEY="$MINIO_APP_ACCESS_KEY" \
  -e MINIO_APP_SECRET_KEY="$MINIO_APP_SECRET_KEY" \
  -e ROBOT_DH_LAKE_BUCKET="$ROBOT_DH_LAKE_BUCKET" \
  minio/mc:latest \
  -c "$MC_SCRIPT"
