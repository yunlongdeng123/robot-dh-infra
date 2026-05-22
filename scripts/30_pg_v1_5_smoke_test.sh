#!/usr/bin/env bash
set -euo pipefail

# v1.5 PostgreSQL smoke test：
#   - 检查 6 张新表是否存在
#   - 用应用账号 robot_dh_app 在每张表里插入 + 删除一行 smoke 数据
#   - 退出码非 0 = 失败
#
# 不污染线上数据，所有 smoke 行均在事务内插入后立即删除。

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
ENV_FILE="$PROJECT_DIR/.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE not found. Run ./scripts/03_generate_env.sh first." >&2
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker is not installed." >&2
  exit 1
fi

if ! docker inspect robot-dh-postgres >/dev/null 2>&1; then
  echo "ERROR: PostgreSQL container robot-dh-postgres is not available." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

RUN_ID="v15_smoke_$(date -u +%Y%m%d_%H%M%S)"
JOB_ID="job_${RUN_ID}"
PLAN_ID="plan_${RUN_ID}"
BENCH_ID="bench_${RUN_ID}"
CASE_ID="case_${RUN_ID}"
WF_NAME="wf_${RUN_ID}"
EVENT_ID="evt_${RUN_ID}"

SQL=$(cat <<EOF
-- 表存在性检查
DO \$\$
DECLARE
  missing_tables text;
BEGIN
  SELECT string_agg(name, ', ' ORDER BY name)
    INTO missing_tables
  FROM (VALUES
    ('etl_perf_runs'),
    ('etl_shards'),
    ('benchmark_runs'),
    ('benchmark_cases'),
    ('argo_workflow_runs'),
    ('runtime_events')
  ) AS required(name)
  WHERE to_regclass('public.' || name) IS NULL;

  IF missing_tables IS NOT NULL THEN
    RAISE EXCEPTION 'Missing v1.5 tables: %', missing_tables;
  END IF;
END
\$\$;

BEGIN;

INSERT INTO etl_perf_runs (job_id, run_id, dataset_id, version, phase, input_uri, output_uri,
                           input_bytes, output_bytes, input_rows, output_rows, duration_sec,
                           download_duration_sec, upload_duration_sec, compute_duration_sec,
                           peak_memory_mb, worker_id, status, metrics_json)
VALUES ('${JOB_ID}', '${RUN_ID}', 'smoke_dataset', '${RUN_ID}', 'normalize',
        's3://robot-lake/raw/smoke_dataset/${RUN_ID}/',
        's3://robot-lake/ods/smoke_dataset/${RUN_ID}/',
        1024, 2048, 10, 10, 0.5, 0.1, 0.1, 0.3, 64, 'smoke-worker', 'success',
        jsonb_build_object('smoke', true));

INSERT INTO etl_shards (plan_id, shard_id, shard_uri, dataset_count, input_bytes, status, assigned_worker, metrics_json)
VALUES ('${PLAN_ID}', 0, 's3://robot-lake/tmp/${PLAN_ID}/shard_0/', 1, 1024, 'success', 'smoke-worker',
        jsonb_build_object('smoke', true));

INSERT INTO benchmark_runs (benchmark_id, suite_name, status, started_at, finished_at, duration_sec, metrics_json)
VALUES ('${BENCH_ID}', 'smoke_suite', 'success', now(), now(), 0.25,
        jsonb_build_object('smoke', true));

INSERT INTO benchmark_cases (benchmark_id, case_id, dataset_uri, mutation_type, expected_status, actual_status,
                             expected_failed_validators, actual_failed_validators, passed, metrics_json, artifacts_uri)
VALUES ('${BENCH_ID}', '${CASE_ID}', 's3://robot-lake/tmp/${BENCH_ID}/',
        'noop', 'pass', 'pass',
        '[]'::jsonb, '[]'::jsonb, TRUE,
        jsonb_build_object('smoke', true),
        's3://robot-dh-artifacts/tmp/${BENCH_ID}/${CASE_ID}/');

INSERT INTO argo_workflow_runs (workflow_name, workflow_uid, workflow_namespace, entrypoint, status,
                                started_at, finished_at, duration_sec, workflow_json, metrics_json)
VALUES ('${WF_NAME}', '${RUN_ID}', 'robot-dh', 'smoke-entry', 'Succeeded',
        now(), now(), 0.5,
        jsonb_build_object('smoke', true),
        jsonb_build_object('smoke', true));

INSERT INTO runtime_events (event_id, event_type, source, run_id, job_id, workflow_name, dataset_id, version, payload_json)
VALUES ('${EVENT_ID}', 'smoke.event', 'pg_smoke_test', '${RUN_ID}', '${JOB_ID}', '${WF_NAME}',
        'smoke_dataset', '${RUN_ID}', jsonb_build_object('smoke', true));

-- 清理：保证 smoke 不留痕
DELETE FROM runtime_events     WHERE event_id = '${EVENT_ID}';
DELETE FROM argo_workflow_runs WHERE workflow_name = '${WF_NAME}' AND workflow_uid = '${RUN_ID}';
DELETE FROM benchmark_cases    WHERE benchmark_id = '${BENCH_ID}' AND case_id = '${CASE_ID}';
DELETE FROM benchmark_runs     WHERE benchmark_id = '${BENCH_ID}';
DELETE FROM etl_shards         WHERE plan_id = '${PLAN_ID}';
DELETE FROM etl_perf_runs      WHERE job_id = '${JOB_ID}' AND run_id = '${RUN_ID}';

COMMIT;
EOF
)

printf '%s\n' "$SQL" | docker exec -i \
  -e PGPASSWORD="$ROBOT_DH_APP_PASSWORD" \
  robot-dh-postgres \
  psql -v ON_ERROR_STOP=1 -U "$ROBOT_DH_APP_USER" -d "$POSTGRES_DB" -P pager=off -f -

echo "v1.5 PostgreSQL smoke test passed (run_id=$RUN_ID)"
