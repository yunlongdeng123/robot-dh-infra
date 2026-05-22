#!/usr/bin/env bash
set -euo pipefail

export ROBOT_DH_DB_URI="postgresql+psycopg://robot_dh_app:CHANGE_ME_APP_PASSWORD@127.0.0.1:15432/robot_dh"
export ROBOT_DH_S3_ENDPOINT_URL="http://127.0.0.1:19000"
export ROBOT_DH_S3_ACCESS_KEY="robotdhapp"
export ROBOT_DH_S3_SECRET_KEY="CHANGE_ME_MINIO_APP_SECRET"
export ROBOT_DH_S3_DATA_BUCKET="robot-datasets"
export ROBOT_DH_S3_ARTIFACT_BUCKET="robot-dh-artifacts"
export ROBOT_DH_REDIS_URL="redis://:CHANGE_ME_REDIS_PASSWORD@127.0.0.1:16379/0"