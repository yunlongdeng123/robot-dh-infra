#!/usr/bin/env bash
# robot-dh v1.4 lake K8s Secret 创建脚本示例。
#
# 用法：
#   1) 把下面的 CHANGE_ME_* / PUBLIC_SERVER_IP_OR_DNS 占位符替换成真实值。
#      建议从 client/robot-dh-lake.env （由 24_export_lake_client_env.sh --show-secrets 生成）里读取。
#   2) 确认 kubectl 当前 context 指向目标 kind/K8s 集群。
#   3) 确认 namespace `robot-dh` 已经存在，必要时执行：
#        kubectl create namespace robot-dh
#   4) 执行本脚本。脚本使用 `kubectl apply` 因此可重复执行，会按需更新 Secret。
#
# 安全要求：
#   - 不要把真实密码硬编码到这个文件并提交到 git。
#   - 推荐通过环境变量注入，例如：
#        ROBOT_DH_APP_PASSWORD=... \
#        MINIO_APP_SECRET_KEY=... \
#        REDIS_PASSWORD=... \
#        PUBLIC_HOST=... \
#        ./client/k8s-create-lake-secret.example.sh
set -euo pipefail

NAMESPACE=${NAMESPACE:-robot-dh}
SECRET_NAME=${SECRET_NAME:-robot-dh-lake-secrets}

PUBLIC_HOST=${PUBLIC_HOST:-PUBLIC_SERVER_IP_OR_DNS}
ROBOT_DH_APP_USER=${ROBOT_DH_APP_USER:-robot_dh_app}
ROBOT_DH_APP_PASSWORD=${ROBOT_DH_APP_PASSWORD:-CHANGE_ME_APP_PASSWORD}
POSTGRES_DB=${POSTGRES_DB:-robot_dh}
DB_PORT=${DB_PORT:-5432}

MINIO_APP_ACCESS_KEY=${MINIO_APP_ACCESS_KEY:-robotdhapp}
MINIO_APP_SECRET_KEY=${MINIO_APP_SECRET_KEY:-CHANGE_ME_MINIO_APP_SECRET}
S3_PORT=${S3_PORT:-9000}

ROBOT_DH_DATA_BUCKET=${ROBOT_DH_DATA_BUCKET:-robot-datasets}
ROBOT_DH_ARTIFACT_BUCKET=${ROBOT_DH_ARTIFACT_BUCKET:-robot-dh-artifacts}
ROBOT_DH_LAKE_BUCKET=${ROBOT_DH_LAKE_BUCKET:-robot-lake}

REDIS_PASSWORD=${REDIS_PASSWORD:-CHANGE_ME_REDIS_PASSWORD}
REDIS_PORT=${REDIS_PORT:-6379}

if ! command -v kubectl >/dev/null 2>&1; then
  echo "ERROR: kubectl is not installed." >&2
  exit 1
fi

kubectl -n "$NAMESPACE" create secret generic "$SECRET_NAME" \
  --from-literal=ROBOT_DH_DB_URI="postgresql+psycopg://${ROBOT_DH_APP_USER}:${ROBOT_DH_APP_PASSWORD}@${PUBLIC_HOST}:${DB_PORT}/${POSTGRES_DB}" \
  --from-literal=ROBOT_DH_ARTIFACT_STORE='s3' \
  --from-literal=ROBOT_DH_S3_ENDPOINT_URL="http://${PUBLIC_HOST}:${S3_PORT}" \
  --from-literal=ROBOT_DH_S3_ACCESS_KEY="${MINIO_APP_ACCESS_KEY}" \
  --from-literal=ROBOT_DH_S3_SECRET_KEY="${MINIO_APP_SECRET_KEY}" \
  --from-literal=ROBOT_DH_S3_DATA_BUCKET="${ROBOT_DH_DATA_BUCKET}" \
  --from-literal=ROBOT_DH_S3_ARTIFACT_BUCKET="${ROBOT_DH_ARTIFACT_BUCKET}" \
  --from-literal=ROBOT_DH_S3_LAKE_BUCKET="${ROBOT_DH_LAKE_BUCKET}" \
  --from-literal=ROBOT_DH_REDIS_URL="redis://:${REDIS_PASSWORD}@${PUBLIC_HOST}:${REDIS_PORT}/0" \
  --dry-run=client \
  -o yaml | kubectl apply -f -

echo "Applied secret $SECRET_NAME in namespace $NAMESPACE."
