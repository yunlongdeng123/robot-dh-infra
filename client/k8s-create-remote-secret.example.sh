#!/usr/bin/env bash
set -euo pipefail

kubectl -n robot-dh create secret generic robot-dh-remote-secrets \
  --from-literal=ROBOT_DH_DB_URI='postgresql+psycopg://robot_dh_app:CHANGE_ME_APP_PASSWORD@PUBLIC_SERVER_IP_OR_DNS:5432/robot_dh' \
  --from-literal=ROBOT_DH_S3_ENDPOINT_URL='http://PUBLIC_SERVER_IP_OR_DNS:9000' \
  --from-literal=ROBOT_DH_S3_ACCESS_KEY='robotdhapp' \
  --from-literal=ROBOT_DH_S3_SECRET_KEY='CHANGE_ME_MINIO_APP_SECRET' \
  --from-literal=ROBOT_DH_S3_DATA_BUCKET='robot-datasets' \
  --from-literal=ROBOT_DH_S3_ARTIFACT_BUCKET='robot-dh-artifacts' \
  --from-literal=ROBOT_DH_REDIS_URL='redis://:CHANGE_ME_REDIS_PASSWORD@PUBLIC_SERVER_IP_OR_DNS:6379/0' \
  --dry-run=client \
  -o yaml | kubectl apply -f -