#!/bin/sh
set -euo pipefail

ROBOT_DH_LAKE_BUCKET="${ROBOT_DH_LAKE_BUCKET:-robot-lake}"

warn() {
  printf 'WARNING: %s\n' "$*" >&2
}

info() {
  printf '%s\n' "$*"
}

wait_for_alias() {
  attempt=1
  while [ "$attempt" -le 30 ]; do
    if mc alias set local http://minio:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
    attempt=$((attempt + 1))
  done
  return 1
}

wait_for_ready() {
  attempt=1
  while [ "$attempt" -le 30 ]; do
    if mc ready local >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
    attempt=$((attempt + 1))
  done
  return 1
}

create_bucket() {
  bucket="$1"
  if mc mb --ignore-existing "local/$bucket" >/dev/null 2>&1; then
    info "Bucket ready: $bucket"
  else
    warn "Failed to ensure bucket exists: $bucket"
  fi

  if mc version enable "local/$bucket" >/dev/null 2>&1; then
    info "Versioning enabled: $bucket"
  else
    warn "Could not enable versioning on bucket: $bucket"
  fi
}

if ! wait_for_alias; then
  warn "MinIO alias setup failed; skipping bucket bootstrap."
  exit 0
fi

if ! wait_for_ready; then
  warn "MinIO did not report ready status; skipping bucket bootstrap."
  exit 0
fi

create_bucket "$ROBOT_DH_DATA_BUCKET"
create_bucket "$ROBOT_DH_ARTIFACT_BUCKET"
create_bucket "$ROBOT_DH_BACKUP_BUCKET"
create_bucket "$ROBOT_DH_LAKE_BUCKET"

policy_name="robot-dh-readwrite"
lake_policy_name="robot-dh-lake-readwrite"
policy_ready=0
lake_policy_ready=0
app_user_ready=0

if mc admin policy info local "$policy_name" >/dev/null 2>&1; then
  info "Policy already exists: $policy_name"
  policy_ready=1
elif mc admin policy create local "$policy_name" /policies/robot_dh_readwrite.json >/dev/null 2>&1; then
  info "Policy created: $policy_name"
  policy_ready=1
else
  warn "Could not create policy $policy_name; client access may need root credentials."
fi

if mc admin policy info local "$lake_policy_name" >/dev/null 2>&1; then
  info "Policy already exists: $lake_policy_name"
  lake_policy_ready=1
elif mc admin policy create local "$lake_policy_name" /policies/robot_dh_lake_readwrite.json >/dev/null 2>&1; then
  info "Policy created: $lake_policy_name"
  lake_policy_ready=1
else
  warn "Could not create policy $lake_policy_name; robot-lake access may need root credentials."
fi

if mc admin user info local "$MINIO_APP_ACCESS_KEY" >/dev/null 2>&1; then
  info "App user already exists: $MINIO_APP_ACCESS_KEY"
  app_user_ready=1
elif mc admin user add local "$MINIO_APP_ACCESS_KEY" "$MINIO_APP_SECRET_KEY" >/dev/null 2>&1; then
  info "App user created: $MINIO_APP_ACCESS_KEY"
  app_user_ready=1
else
  warn "Could not create MinIO app user; temporarily use root credentials and rotate later."
fi

if [ "$policy_ready" -eq 1 ] && [ "$app_user_ready" -eq 1 ]; then
  if mc admin policy attach local "$policy_name" --user "$MINIO_APP_ACCESS_KEY" >/dev/null 2>&1; then
    info "Policy attached to app user via mc admin policy attach."
  elif mc admin policy set local "$policy_name" user="$MINIO_APP_ACCESS_KEY" >/dev/null 2>&1; then
    info "Policy attached to app user via legacy mc admin policy set."
  else
    warn "Could not attach policy to app user; temporarily use root credentials and rotate later."
  fi
fi

if [ "$lake_policy_ready" -eq 1 ] && [ "$app_user_ready" -eq 1 ]; then
  if mc admin policy attach local "$lake_policy_name" --user "$MINIO_APP_ACCESS_KEY" >/dev/null 2>&1; then
    info "Lake policy attached to app user via mc admin policy attach."
  else
    warn "Could not attach lake policy to app user; robot-lake may still require root credentials."
  fi
fi

info "Current buckets:"
if ! mc ls local; then
  warn "Could not list MinIO buckets after initialization."
fi

exit 0
