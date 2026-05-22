#!/usr/bin/env bash
set -euo pipefail

STATUS=0

parse_host_port_from_uri() {
  local input="$1"
  local hostport
  hostport=$(printf '%s\n' "$input" | sed -E 's#^[^@]+@([^/?]+).*#\1#')
  printf '%s\n' "$hostport"
}

parse_host_port_from_http() {
  local input="$1"
  local without_scheme
  without_scheme="${input#http://}"
  without_scheme="${without_scheme#https://}"
  without_scheme="${without_scheme%%/*}"
  printf '%s\n' "$without_scheme"
}

tcp_probe() {
  local host="$1"
  local port="$2"
  timeout 5 bash -lc "exec 3<>/dev/tcp/$host/$port" >/dev/null 2>&1
}

check_cmd() {
  local label="$1"
  shift
  echo "== $label =="
  if "$@"; then
    :
  else
    STATUS=1
  fi
  echo
}

check_shell() {
  local label="$1"
  local command="$2"
  echo "== $label =="
  if bash -lc "$command"; then
    :
  else
    STATUS=1
  fi
  echo
}

echo "WSL remote doctor"
echo "Date (UTC): $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo

required_vars=(
  ROBOT_DH_DB_URI
  ROBOT_DH_S3_ENDPOINT_URL
  ROBOT_DH_S3_ACCESS_KEY
  ROBOT_DH_S3_SECRET_KEY
  ROBOT_DH_S3_DATA_BUCKET
  ROBOT_DH_S3_ARTIFACT_BUCKET
  ROBOT_DH_REDIS_URL
)

db_hostport=$(parse_host_port_from_uri "$ROBOT_DH_DB_URI")
db_host="${db_hostport%%:*}"
db_port="${db_hostport##*:}"
s3_hostport=$(parse_host_port_from_http "$ROBOT_DH_S3_ENDPOINT_URL")
s3_host="${s3_hostport%%:*}"
s3_port="${s3_hostport##*:}"
if [[ "$s3_port" == "$s3_hostport" ]]; then
  s3_port=80
fi
redis_hostport=$(parse_host_port_from_uri "$ROBOT_DH_REDIS_URL")
redis_host="${redis_hostport%%:*}"
redis_port="${redis_hostport##*:}"

MODE=public
if [[ "$db_host" == "127.0.0.1" || "$db_host" == "localhost" ]] && [[ "$db_port" == "15432" ]]; then
  MODE=tunnel
fi

echo "== connection mode =="
echo "$MODE"
echo "PostgreSQL target: $db_host:$db_port"
echo "MinIO target: $s3_host:$s3_port"
echo "Redis target: $redis_host:$redis_port"
echo

echo "== environment variables =="
for var_name in "${required_vars[@]}"; do
  if [[ -n "${!var_name:-}" ]]; then
    echo "OK   $var_name"
  else
    echo "MISS $var_name"
    STATUS=1
  fi
done
echo

if [[ "$MODE" == "tunnel" ]]; then
  check_shell "tunnel ports" "ss -ltn '( sport = :15432 or sport = :19000 or sport = :19001 or sport = :16379 )'"
else
  check_cmd "postgres tcp reachability" tcp_probe "$db_host" "$db_port"
  check_cmd "minio tcp reachability" tcp_probe "$s3_host" "$s3_port"
  check_cmd "redis tcp reachability" tcp_probe "$redis_host" "$redis_port"
fi

echo "== local client tools =="
for tool_name in psql redis-cli curl ssh; do
  if command -v "$tool_name" >/dev/null 2>&1; then
    echo "OK   $tool_name"
  else
    echo "MISS $tool_name"
    if [[ "$tool_name" != "psql" && "$tool_name" != "redis-cli" ]]; then
      STATUS=1
    fi
  fi
done
echo

if command -v psql >/dev/null 2>&1 && [[ -n "${ROBOT_DH_DB_URI:-}" ]]; then
  check_shell "postgres query" "psql \"$ROBOT_DH_DB_URI\" -Atqc 'select current_database(), current_user;'"
else
  echo "== postgres query =="
  echo "SKIP psql is not installed or ROBOT_DH_DB_URI is missing"
  echo
fi

if command -v redis-cli >/dev/null 2>&1 && [[ -n "${ROBOT_DH_REDIS_URL:-}" ]]; then
  check_shell "redis ping" "redis-cli -u \"$ROBOT_DH_REDIS_URL\" ping"
else
  echo "== redis ping =="
  echo "SKIP redis-cli is not installed or ROBOT_DH_REDIS_URL is missing"
  echo
fi

if command -v curl >/dev/null 2>&1 && [[ -n "${ROBOT_DH_S3_ENDPOINT_URL:-}" ]]; then
  check_shell "minio health" "curl -fsS \"$ROBOT_DH_S3_ENDPOINT_URL/minio/health/live\" >/dev/null"
else
  echo "== minio health =="
  echo "SKIP curl is not installed or ROBOT_DH_S3_ENDPOINT_URL is missing"
  echo
fi

exit "$STATUS"