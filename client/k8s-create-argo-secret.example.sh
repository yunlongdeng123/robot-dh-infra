#!/usr/bin/env bash
# robot-dh v1.5 Argo Workflows Secret 创建脚本示例。
#
# 用法：
#   1) 从环境变量注入真实凭据，例如：
#        PUBLIC_HOST=public.host.example \
#        ROBOT_DH_APP_PASSWORD=*** \
#        MINIO_APP_SECRET_KEY=*** \
#        REDIS_PASSWORD=*** \
#        ./client/k8s-create-argo-secret.example.sh
#   2) 或者在 WSL host 上 source 由 ./scripts/31_argowf_remote_env_export.sh --show-secrets
#      生成的 client/robot-dh-v1-5.env，再运行本脚本。
#   3) 默认拒绝 127.0.0.1 / localhost；如果你确实在 WSL host 单进程测试，可加 --allow-localhost。
#
# 注意：
#   - 不打印真实 secret 到 stdout / stderr / journald
#   - 使用 kubectl apply，可重复执行
set -euo pipefail

NAMESPACE=${NAMESPACE:-robot-dh}
SECRET_NAME=${SECRET_NAME:-robot-dh-v1-5-secrets}
ALLOW_LOCALHOST=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --allow-localhost) ALLOW_LOCALHOST=1 ;;
    -h|--help)
      cat <<EOF >&2
Usage: $0 [--allow-localhost]

Required env (will be reduced to placeholders if unset, kubectl apply will fail):
  PUBLIC_HOST            必填，公网 IP 或 DNS（kind Pod 必须可路由）
  ROBOT_DH_APP_PASSWORD  PostgreSQL 应用账号密码
  MINIO_APP_SECRET_KEY   MinIO 应用 secret
  REDIS_PASSWORD         Redis 密码

Optional env (默认值与 .env 一致):
  ROBOT_DH_APP_USER       默认 robot_dh_app
  POSTGRES_DB             默认 robot_dh
  DB_PORT                 默认 5432
  MINIO_APP_ACCESS_KEY    默认 robotdhapp
  S3_PORT                 默认 9000
  REDIS_PORT              默认 6379
  ROBOT_DH_DATA_BUCKET    默认 robot-datasets
  ROBOT_DH_ARTIFACT_BUCKET 默认 robot-dh-artifacts
  ROBOT_DH_LAKE_BUCKET    默认 robot-lake
EOF
      exit 0
      ;;
    *) echo "ERROR: unknown arg: $1" >&2; exit 1 ;;
  esac
  shift
done

PUBLIC_HOST=${PUBLIC_HOST:-PUBLIC_SERVER_IP_OR_DNS}

if [[ $ALLOW_LOCALHOST -ne 1 ]]; then
  case "$PUBLIC_HOST" in
    127.0.0.1|localhost|::1)
      echo "ERROR: PUBLIC_HOST=$PUBLIC_HOST 不能在 kind / Argo Pod 中工作。" >&2
      echo "       Pod 内的 127.0.0.1 指向 Pod 自己，不会进入 WSL host 的 SSH tunnel。" >&2
      echo "       请改用云端公网 IP/DNS；如果只是 WSL host 上的单进程测试，可加 --allow-localhost。" >&2
      exit 1
      ;;
  esac
fi

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

# 检查 namespace 是否存在，缺失则提示但不自动创建（与 robot-dh-lake 模板保持一致）
if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
  echo "ERROR: namespace $NAMESPACE 不存在。请先：" >&2
  echo "       kubectl create namespace $NAMESPACE" >&2
  echo "       或者：kubectl apply -f client/k8s-argo-secret.example.yaml" >&2
  exit 1
fi

# 不要把真实密码 echo 出来；统一交给 kubectl apply
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
echo "PUBLIC_HOST=$PUBLIC_HOST (其他凭据已脱敏，不会打印)"
