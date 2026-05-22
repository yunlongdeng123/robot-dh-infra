#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
ENV_FILE="$PROJECT_DIR/.env"
OUTPUT_FILE="$PROJECT_DIR/client/robot-dh-lake.env"
SHOW_SECRETS=0
MODE=tunnel
HOST_OVERRIDE=""

usage() {
  echo "Usage: $0 [--show-secrets] [--mode tunnel|public] [--host PUBLIC_HOST_OR_DNS]" >&2
}

mask() {
  local value="$1"
  if [[ -z "$value" ]]; then
    printf 'UNSET'
  elif [[ ${#value} -le 8 ]]; then
    printf '%*s' "${#value}" '' | tr ' ' '*'
  else
    printf '%s****%s' "${value:0:4}" "${value: -4}"
  fi
}

detect_public_host() {
  if [[ -n "${PUBLIC_HOST:-}" ]]; then
    printf '%s\n' "$PUBLIC_HOST"
    return 0
  fi

  if command -v curl >/dev/null 2>&1; then
    if detected_host=$(curl -4 --connect-timeout 5 -fsS ifconfig.me 2>/dev/null); then
      printf '%s\n' "$detected_host"
      return 0
    fi
  fi

  echo "ERROR: Could not detect public host automatically. Re-run with --host <PUBLIC_IP_OR_DNS>." >&2
  return 1
}

render_env() {
  local db_password="$1"
  local s3_access_key="$2"
  local s3_secret_key="$3"
  local redis_password="$4"

  cat <<EOF
ROBOT_DH_DB_URI=postgresql+psycopg://$ROBOT_DH_APP_USER:$db_password@$CLIENT_HOST:$DB_PORT/$POSTGRES_DB
ROBOT_DH_ARTIFACT_STORE=s3
ROBOT_DH_S3_ENDPOINT_URL=http://$CLIENT_HOST:$S3_PORT
ROBOT_DH_S3_ACCESS_KEY=$s3_access_key
ROBOT_DH_S3_SECRET_KEY=$s3_secret_key
ROBOT_DH_S3_DATA_BUCKET=$ROBOT_DH_DATA_BUCKET
ROBOT_DH_S3_ARTIFACT_BUCKET=$ROBOT_DH_ARTIFACT_BUCKET
ROBOT_DH_S3_LAKE_BUCKET=$ROBOT_DH_LAKE_BUCKET
ROBOT_DH_REDIS_URL=redis://:$redis_password@$CLIENT_HOST:$REDIS_PORT/0
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --show-secrets)
      SHOW_SECRETS=1
      ;;
    --mode)
      shift
      if [[ $# -eq 0 ]]; then
        usage
        exit 1
      fi
      MODE="$1"
      ;;
    --host)
      shift
      if [[ $# -eq 0 ]]; then
        usage
        exit 1
      fi
      HOST_OVERRIDE="$1"
      ;;
    *)
      usage
      exit 1
      ;;
  esac
  shift
done

if [[ "$MODE" != "tunnel" && "$MODE" != "public" ]]; then
  echo "ERROR: --mode must be either 'tunnel' or 'public'." >&2
  exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE not found. Run ./scripts/03_generate_env.sh first." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

ROBOT_DH_LAKE_BUCKET="${ROBOT_DH_LAKE_BUCKET:-robot-lake}"

if [[ "$MODE" == "tunnel" ]]; then
  CLIENT_HOST=127.0.0.1
  DB_PORT=15432
  S3_PORT=19000
  REDIS_PORT=16379
else
  CLIENT_HOST="$HOST_OVERRIDE"
  if [[ -z "$CLIENT_HOST" ]]; then
    CLIENT_HOST=$(detect_public_host)
  fi
  DB_PORT=5432
  S3_PORT=9000
  REDIS_PORT=6379
fi

if [[ $SHOW_SECRETS -eq 1 ]]; then
  render_env "$ROBOT_DH_APP_PASSWORD" "$MINIO_APP_ACCESS_KEY" "$MINIO_APP_SECRET_KEY" "$REDIS_PASSWORD" > "$OUTPUT_FILE"
  chmod 600 "$OUTPUT_FILE"
  echo "Mode: $MODE"
  echo "Client host: $CLIENT_HOST"
  echo "Wrote real client env to $OUTPUT_FILE"
else
  render_env "$(mask "$ROBOT_DH_APP_PASSWORD")" "$(mask "$MINIO_APP_ACCESS_KEY")" "$(mask "$MINIO_APP_SECRET_KEY")" "$(mask "$REDIS_PASSWORD")"
  echo
  echo "Mode: $MODE"
  echo "Client host: $CLIENT_HOST"
  echo "Secrets are masked. Re-run with --show-secrets to write $OUTPUT_FILE."
fi