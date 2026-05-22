#!/usr/bin/env bash
set -euo pipefail

# v1.5 Argo Workflows 远程访问 env 导出。
#
# 默认输出脱敏版到 stdout；--show-secrets 时把真实凭据写到
# client/robot-dh-v1-5.env（权限 600），同时 stdout 仍保持脱敏。
#
# 与 24_export_lake_client_env.sh 的差别：
#   - 输出文件名固定 client/robot-dh-v1-5.env
#   - 默认 mode=public，因为 kind Pod 不能用 WSL 127.0.0.1 SSH tunnel
#   - 增加 ROBOT_DH_ARGO_NAMESPACE / ROBOT_DH_ENV / ROBOT_DH_RELEASE_VERSION
#
# 用法：
#   ./scripts/31_argowf_remote_env_export.sh
#   ./scripts/31_argowf_remote_env_export.sh --show-secrets
#   ./scripts/31_argowf_remote_env_export.sh --mode tunnel
#   ./scripts/31_argowf_remote_env_export.sh --host my.public.host

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
ENV_FILE="$PROJECT_DIR/.env"
OUTPUT_FILE="$PROJECT_DIR/client/robot-dh-v1-5.env"

SHOW_SECRETS=0
MODE=public
HOST_OVERRIDE=""

usage() {
  cat <<EOF >&2
Usage: $0 [--show-secrets] [--mode tunnel|public] [--host PUBLIC_HOST_OR_DNS]

默认 mode=public。kind / Argo 不允许 mode=tunnel（127.0.0.1 在 Pod 内不可路由）。
EOF
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
    if detected=$(curl -4 --connect-timeout 5 -fsS ifconfig.me 2>/dev/null); then
      printf '%s\n' "$detected"
      return 0
    fi
  fi
  echo "ERROR: 无法自动探测公网 host。请加 --host <PUBLIC_IP_OR_DNS>" >&2
  return 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --show-secrets) SHOW_SECRETS=1 ;;
    --mode)
      shift
      [[ $# -gt 0 ]] || { usage; exit 1; }
      MODE="$1"
      ;;
    --host)
      shift
      [[ $# -gt 0 ]] || { usage; exit 1; }
      HOST_OVERRIDE="$1"
      ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
  shift
done

if [[ "$MODE" != "tunnel" && "$MODE" != "public" ]]; then
  echo "ERROR: --mode must be tunnel or public" >&2
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

ROBOT_DH_DATA_BUCKET="${ROBOT_DH_DATA_BUCKET:-robot-datasets}"
ROBOT_DH_ARTIFACT_BUCKET="${ROBOT_DH_ARTIFACT_BUCKET:-robot-dh-artifacts}"
ROBOT_DH_BACKUP_BUCKET="${ROBOT_DH_BACKUP_BUCKET:-robot-dh-backups}"
ROBOT_DH_LAKE_BUCKET="${ROBOT_DH_LAKE_BUCKET:-robot-lake}"
ARGO_NAMESPACE="${ROBOT_DH_ARGO_NAMESPACE:-robot-dh}"
RELEASE_VERSION="${ROBOT_DH_RELEASE_VERSION:-v1.5}"

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

render_env() {
  local db_password="$1"
  local s3_access_key="$2"
  local s3_secret_key="$3"
  local redis_password="$4"

  cat <<EOF
# robot-dh ${RELEASE_VERSION} Argo Workflows client env (mode=${MODE})
# 不要把真实密码提交到 git；--show-secrets 生成的文件已 chmod 600。
ROBOT_DH_RELEASE_VERSION=${RELEASE_VERSION}
ROBOT_DH_ARGO_NAMESPACE=${ARGO_NAMESPACE}
ROBOT_DH_DB_URI=postgresql+psycopg://${ROBOT_DH_APP_USER}:${db_password}@${CLIENT_HOST}:${DB_PORT}/${POSTGRES_DB}
ROBOT_DH_ARTIFACT_STORE=s3
ROBOT_DH_S3_ENDPOINT_URL=http://${CLIENT_HOST}:${S3_PORT}
ROBOT_DH_S3_ACCESS_KEY=${s3_access_key}
ROBOT_DH_S3_SECRET_KEY=${s3_secret_key}
ROBOT_DH_S3_DATA_BUCKET=${ROBOT_DH_DATA_BUCKET}
ROBOT_DH_S3_ARTIFACT_BUCKET=${ROBOT_DH_ARTIFACT_BUCKET}
ROBOT_DH_S3_BACKUP_BUCKET=${ROBOT_DH_BACKUP_BUCKET}
ROBOT_DH_S3_LAKE_BUCKET=${ROBOT_DH_LAKE_BUCKET}
ROBOT_DH_REDIS_URL=redis://:${redis_password}@${CLIENT_HOST}:${REDIS_PORT}/0
EOF
}

if [[ $SHOW_SECRETS -eq 1 ]]; then
  mkdir -p "$(dirname "$OUTPUT_FILE")"
  render_env \
    "$ROBOT_DH_APP_PASSWORD" \
    "$MINIO_APP_ACCESS_KEY" \
    "$MINIO_APP_SECRET_KEY" \
    "$REDIS_PASSWORD" > "$OUTPUT_FILE"
  chmod 600 "$OUTPUT_FILE"
  # stdout 始终给脱敏版，避免被 CI / journald 抓走
  render_env \
    "$(mask "$ROBOT_DH_APP_PASSWORD")" \
    "$(mask "$MINIO_APP_ACCESS_KEY")" \
    "$(mask "$MINIO_APP_SECRET_KEY")" \
    "$(mask "$REDIS_PASSWORD")"
  echo
  echo "Mode: $MODE"
  echo "Client host: $CLIENT_HOST"
  echo "Argo namespace: $ARGO_NAMESPACE"
  echo "Wrote real env to: $OUTPUT_FILE (chmod 600)"
else
  render_env \
    "$(mask "$ROBOT_DH_APP_PASSWORD")" \
    "$(mask "$MINIO_APP_ACCESS_KEY")" \
    "$(mask "$MINIO_APP_SECRET_KEY")" \
    "$(mask "$REDIS_PASSWORD")"
  echo
  echo "Mode: $MODE"
  echo "Client host: $CLIENT_HOST"
  echo "Argo namespace: $ARGO_NAMESPACE"
  echo "Secrets are masked. Re-run with --show-secrets to write $OUTPUT_FILE."
fi
