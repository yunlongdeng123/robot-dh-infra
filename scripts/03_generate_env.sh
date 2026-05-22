#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
ENV_FILE="$PROJECT_DIR/.env"
FORCE=0

usage() {
  echo "Usage: $0 [--force]" >&2
}

if [[ $# -gt 1 ]]; then
  usage
  exit 1
fi

if [[ $# -eq 1 ]]; then
  if [[ "$1" != "--force" ]]; then
    usage
    exit 1
  fi
  FORCE=1
fi

if ! command -v openssl >/dev/null 2>&1; then
  echo "ERROR: openssl is required to generate secrets." >&2
  exit 1
fi

if [[ -f "$ENV_FILE" && $FORCE -ne 1 ]]; then
  echo ".env already exists at $ENV_FILE. Re-run with --force to replace it."
  exit 0
fi

random_secret() {
  openssl rand -hex 24
}

tmp_file=$(mktemp "$PROJECT_DIR/.env.tmp.XXXXXX")
trap 'rm -f "$tmp_file"' EXIT
umask 077

cat > "$tmp_file" <<EOF
COMPOSE_PROJECT_NAME=robot_dh_infra
BIND_ADDR=127.0.0.1
TRUSTED_CIDR=
SSH_TRUSTED_CIDR=
POSTGRES_APP_TRUSTED_CIDRS=
POSTGRES_APP_HBA_METHOD=md5

POSTGRES_IMAGE=postgres:16-alpine
POSTGRES_DB=robot_dh
POSTGRES_USER=robot_dh_admin
POSTGRES_PASSWORD=$(random_secret)
ROBOT_DH_APP_USER=robot_dh_app
ROBOT_DH_APP_PASSWORD=$(random_secret)

MINIO_IMAGE=minio/minio:latest
MINIO_ROOT_USER=robotdhadmin
MINIO_ROOT_PASSWORD=$(random_secret)
MINIO_APP_ACCESS_KEY=robotdhapp
MINIO_APP_SECRET_KEY=$(random_secret)

REDIS_IMAGE=redis:7-alpine
REDIS_PASSWORD=$(random_secret)

ROBOT_DH_DATA_BUCKET=robot-datasets
ROBOT_DH_ARTIFACT_BUCKET=robot-dh-artifacts
ROBOT_DH_BACKUP_BUCKET=robot-dh-backups
EOF

mv "$tmp_file" "$ENV_FILE"
chmod 600 "$ENV_FILE"
trap - EXIT

echo "Generated $ENV_FILE with fresh secrets."
echo "Next commands:"
echo "  source .env"
echo "  docker compose config"