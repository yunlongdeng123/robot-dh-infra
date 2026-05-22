#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
ENV_FILE="$PROJECT_DIR/.env"
POLICY_FILE="$PROJECT_DIR/minio/policies/robot_dh_lake_readwrite.json"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE not found. Run ./scripts/03_generate_env.sh first." >&2
  exit 1
fi

if [[ ! -f "$POLICY_FILE" ]]; then
  echo "ERROR: Lake policy file not found: $POLICY_FILE" >&2
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

run_mc() {
  local script="$1"

  docker run --rm \
    --entrypoint sh \
    --network robot-dh-net \
    -e MINIO_ROOT_USER="$MINIO_ROOT_USER" \
    -e MINIO_ROOT_PASSWORD="$MINIO_ROOT_PASSWORD" \
    -e MINIO_APP_ACCESS_KEY="$MINIO_APP_ACCESS_KEY" \
    -e MINIO_APP_SECRET_KEY="$MINIO_APP_SECRET_KEY" \
    -e ROBOT_DH_LAKE_BUCKET="$ROBOT_DH_LAKE_BUCKET" \
    -v "$POLICY_FILE:/policies/robot_dh_lake_readwrite.json:ro" \
    minio/mc:latest \
    -c "$script"
}

read -r -d '' MC_SCRIPT <<'EOF' || true
set -eu

wait_for_minio() {
  attempt=1
  while [ "$attempt" -le 30 ]; do
    if mc alias set local http://robot-dh-minio:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null 2>&1 && mc ready local >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
    attempt=$((attempt + 1))
  done
  return 1
}

ensure_placeholder() {
  object_path="$1"
  if mc stat "local/$object_path" >/dev/null 2>&1; then
    echo "Placeholder ready: $object_path"
    return 0
  fi

  : | mc pipe "local/$object_path" >/dev/null
  echo "Placeholder created: $object_path"
}

if ! wait_for_minio; then
  echo "ERROR: Could not connect to MinIO at robot-dh-minio:9000 with the configured root credentials." >&2
  exit 1
fi

mc mb --ignore-existing "local/$ROBOT_DH_LAKE_BUCKET" >/dev/null
echo "Bucket ready: $ROBOT_DH_LAKE_BUCKET"

if mc version enable "local/$ROBOT_DH_LAKE_BUCKET" >/dev/null 2>&1; then
  echo "Versioning enabled: $ROBOT_DH_LAKE_BUCKET"
else
  echo "WARNING: Could not enable versioning for $ROBOT_DH_LAKE_BUCKET" >&2
fi

ensure_placeholder "$ROBOT_DH_LAKE_BUCKET/raw/.keep"
ensure_placeholder "$ROBOT_DH_LAKE_BUCKET/ods/.keep"
ensure_placeholder "$ROBOT_DH_LAKE_BUCKET/dwd/.keep"
ensure_placeholder "$ROBOT_DH_LAKE_BUCKET/ads/quality/.keep"
ensure_placeholder "$ROBOT_DH_LAKE_BUCKET/lineage/events/.keep"
ensure_placeholder "$ROBOT_DH_LAKE_BUCKET/tmp/.keep"

if mc admin policy info local robot-dh-lake-readwrite >/dev/null 2>&1; then
  echo "Policy ready: robot-dh-lake-readwrite"
else
  mc admin policy create local robot-dh-lake-readwrite /policies/robot_dh_lake_readwrite.json >/dev/null
  echo "Policy created: robot-dh-lake-readwrite"
fi

if mc admin user info local "$MINIO_APP_ACCESS_KEY" >/dev/null 2>&1; then
  echo "App user ready: $MINIO_APP_ACCESS_KEY"
else
  mc admin user add local "$MINIO_APP_ACCESS_KEY" "$MINIO_APP_SECRET_KEY" >/dev/null
  echo "App user created: $MINIO_APP_ACCESS_KEY"
fi

if mc admin policy attach local robot-dh-lake-readwrite --user "$MINIO_APP_ACCESS_KEY" >/dev/null 2>&1; then
  echo "Policy attached: robot-dh-lake-readwrite -> $MINIO_APP_ACCESS_KEY"
else
  echo "WARNING: Could not attach lake policy to $MINIO_APP_ACCESS_KEY; app-level access to robot-lake may still fail." >&2
fi

echo "Current versioning status:"
mc version info "local/$ROBOT_DH_LAKE_BUCKET"
echo
echo "Current bucket listing:"
mc ls "local/$ROBOT_DH_LAKE_BUCKET"
EOF

run_mc "$MC_SCRIPT"
