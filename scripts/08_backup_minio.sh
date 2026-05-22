#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
ENV_FILE="$PROJECT_DIR/.env"
TIMESTAMP=$(date -u +%Y%m%d_%H%M%S)
BACKUP_ROOT="/data/robot-dh/minio/backups/$TIMESTAMP"

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

mkdir -p "$BACKUP_ROOT"

docker run --rm \
  --entrypoint sh \
  --network robot-dh-net \
  -e MINIO_ROOT_USER="$MINIO_ROOT_USER" \
  -e MINIO_ROOT_PASSWORD="$MINIO_ROOT_PASSWORD" \
  -e ROBOT_DH_DATA_BUCKET="$ROBOT_DH_DATA_BUCKET" \
  -e ROBOT_DH_ARTIFACT_BUCKET="$ROBOT_DH_ARTIFACT_BUCKET" \
  -e ROBOT_DH_BACKUP_BUCKET="$ROBOT_DH_BACKUP_BUCKET" \
  -e ROBOT_DH_LAKE_BUCKET="$ROBOT_DH_LAKE_BUCKET" \
  -v "$BACKUP_ROOT:/backup" \
  minio/mc:latest \
  -c '
    set -eu
    mc alias set local http://robot-dh-minio:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null
    for bucket in "$ROBOT_DH_DATA_BUCKET" "$ROBOT_DH_ARTIFACT_BUCKET" "$ROBOT_DH_BACKUP_BUCKET" "$ROBOT_DH_LAKE_BUCKET"; do
      echo "Mirroring $bucket"
      mkdir -p "/backup/$bucket"
      mc mirror --overwrite "local/$bucket" "/backup/$bucket"
    done
    mc ls local
  '

echo "MinIO mirror backup completed under $BACKUP_ROOT"
