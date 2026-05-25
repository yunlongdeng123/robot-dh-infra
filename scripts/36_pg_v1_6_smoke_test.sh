#!/usr/bin/env bash
set -euo pipefail

# v1.6 PostgreSQL smoke test：
#   - 检查 9 张新表是否存在
#   - 用应用账号 ROBOT_DH_APP_USER 在每张表中插入 smoke 数据
#   - 事务结束前删除所有 smoke 数据，不留痕
#   - 退出码非 0 = 失败（表缺失 / 权限不足 / 列缺失）
#
# 覆盖：
#   qc_contracts, qc_contract_runs,
#   workflow_runs, workflow_steps,
#   asset_profiles, ml_ready_datasets,
#   dataset_partitions, task_heartbeats,
#   openlineage_events

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

: "${POSTGRES_DB:?POSTGRES_DB not set in .env}"
: "${ROBOT_DH_APP_USER:?ROBOT_DH_APP_USER not set in .env}"
: "${ROBOT_DH_APP_PASSWORD:?ROBOT_DH_APP_PASSWORD not set in .env}"

RUN_TAG="v16_smoke_$(date -u +%Y%m%d_%H%M%S)"
CONTRACT_ID="contract_${RUN_TAG}"
RUN_ID="run_${RUN_TAG}"
WF_NAME="wf_${RUN_TAG}"
STEP_NAME="step_${RUN_TAG}"
PROFILE_ID="profile_${RUN_TAG}"
PARTITION_ID="partition_${RUN_TAG}"
TASK_ID="task_${RUN_TAG}"
EVENT_ID="evt_${RUN_TAG}"
DATASET_ID="smoke_dataset"
VERSION="${RUN_TAG}"
DATASET_FAMILY="smoke_family"
ML_OUTPUT_URI="s3://robot-lake/ml-ready/${DATASET_ID}/${VERSION}/smoke/"

SQL=$(cat <<EOF
-- 表存在性检查：缺失任意一张都立即 raise
DO \$\$
DECLARE
  missing_tables text;
BEGIN
  SELECT string_agg(name, ', ' ORDER BY name)
    INTO missing_tables
  FROM (VALUES
    ('qc_contracts'),
    ('qc_contract_runs'),
    ('workflow_runs'),
    ('workflow_steps'),
    ('asset_profiles'),
    ('ml_ready_datasets'),
    ('dataset_partitions'),
    ('task_heartbeats'),
    ('openlineage_events')
  ) AS required(name)
  WHERE to_regclass('public.' || name) IS NULL;

  IF missing_tables IS NOT NULL THEN
    RAISE EXCEPTION 'Missing v1.6 tables: %', missing_tables;
  END IF;
END
\$\$;

BEGIN;

INSERT INTO qc_contracts (contract_id, dataset_family, version, description,
                          rules_json, enabled)
VALUES ('${CONTRACT_ID}', '${DATASET_FAMILY}', '${VERSION}', 'v1.6 smoke contract',
        jsonb_build_object('rules', jsonb_build_array(
          jsonb_build_object('name', 'smoke_rule', 'kind', 'schema', 'expected', 'noop')
        )),
        TRUE);

INSERT INTO qc_contract_runs (run_id, contract_id, dataset_id, version, dataset_family,
                              dataset_uri, status, started_at, finished_at, duration_sec,
                              metrics_json, failed_rules_json, warning_rules_json,
                              artifacts_uri, error_message)
VALUES ('${RUN_ID}', '${CONTRACT_ID}', '${DATASET_ID}', '${VERSION}', '${DATASET_FAMILY}',
        's3://robot-lake/ods/${DATASET_ID}/${VERSION}/',
        'pass', now(), now(), 0.1,
        jsonb_build_object('smoke', true),
        '[]'::jsonb, '[]'::jsonb,
        's3://robot-lake/qc/${CONTRACT_ID}/${RUN_ID}/',
        NULL);

INSERT INTO workflow_runs (workflow_name, workflow_uid, workflow_namespace,
                           workflow_template, workflow_type, status,
                           started_at, finished_at, duration_sec,
                           parameters_json, metrics_json, workflow_json)
VALUES ('${WF_NAME}', '${RUN_TAG}', 'robot-dh',
        'smoke-template', 'argo', 'Succeeded',
        now(), now(), 0.5,
        jsonb_build_object('smoke', true),
        jsonb_build_object('smoke', true),
        jsonb_build_object('smoke', true));

INSERT INTO workflow_steps (workflow_name, workflow_namespace, step_name, template_name,
                            pod_name, phase, started_at, finished_at, duration_sec,
                            dataset_id, version, dataset_family,
                            input_uri, output_uri, metrics_json, message)
VALUES ('${WF_NAME}', 'robot-dh', '${STEP_NAME}', 'smoke-template',
        'pod-${RUN_TAG}', 'Succeeded', now(), now(), 0.25,
        '${DATASET_ID}', '${VERSION}', '${DATASET_FAMILY}',
        's3://robot-lake/raw/${DATASET_ID}/${VERSION}/',
        's3://robot-lake/ods/${DATASET_ID}/${VERSION}/',
        jsonb_build_object('smoke', true), 'smoke ok');

INSERT INTO asset_profiles (profile_id, dataset_id, version, dataset_family,
                            asset_uri, asset_format, layer,
                            bytes, rows, files_count, episodes_count, videos_count,
                            schema_hash, null_rate, profile_json, status)
VALUES ('${PROFILE_ID}', '${DATASET_ID}', '${VERSION}', '${DATASET_FAMILY}',
        's3://robot-lake/ods/${DATASET_ID}/${VERSION}/pose.parquet',
        'parquet', 'ods',
        2048, 10, 1, 1, 0,
        'smoke-hash', 0.0,
        jsonb_build_object('smoke', true), 'success');

INSERT INTO ml_ready_datasets (dataset_id, version, dataset_family, output_uri,
                               train_uri, val_uri, test_uri,
                               dataset_card_uri, feature_schema_uri,
                               quality_filter_uri, lineage_uri,
                               quality_threshold,
                               num_train, num_val, num_test,
                               status, metrics_json)
VALUES ('${DATASET_ID}', '${VERSION}', '${DATASET_FAMILY}', '${ML_OUTPUT_URI}',
        '${ML_OUTPUT_URI}train/', '${ML_OUTPUT_URI}val/', '${ML_OUTPUT_URI}test/',
        '${ML_OUTPUT_URI}DATASET_CARD.md',
        '${ML_OUTPUT_URI}feature_schema.json',
        '${ML_OUTPUT_URI}quality_filter.json',
        '${ML_OUTPUT_URI}lineage.json',
        0.8,
        8, 1, 1,
        'ready', jsonb_build_object('smoke', true));

INSERT INTO dataset_partitions (partition_id, dataset_id, version, dataset_family,
                                dataset_uri, partition_type, partition_index, partition_uri,
                                input_bytes, estimated_rows, status, metrics_json)
VALUES ('${PARTITION_ID}', '${DATASET_ID}', '${VERSION}', '${DATASET_FAMILY}',
        's3://robot-lake/raw/${DATASET_ID}/${VERSION}/',
        'episode', 0,
        's3://robot-lake/raw/${DATASET_ID}/${VERSION}/episode_0/',
        1024, 100, 'pending', jsonb_build_object('smoke', true));

INSERT INTO task_heartbeats (task_id, workflow_name, step_name,
                             dataset_id, version, phase,
                             progress_current, progress_total, progress_unit,
                             message, metrics_json)
VALUES ('${TASK_ID}', '${WF_NAME}', '${STEP_NAME}',
        '${DATASET_ID}', '${VERSION}', 'normalize',
        5, 10, 'episode',
        'smoke heartbeat', jsonb_build_object('smoke', true));

INSERT INTO openlineage_events (event_id, event_type, event_time,
                                job_namespace, job_name, run_id,
                                inputs_json, outputs_json, facets_json, raw_event_json)
VALUES ('${EVENT_ID}', 'COMPLETE', now(),
        'robot-dh', '${WF_NAME}', '${RUN_TAG}',
        jsonb_build_array(jsonb_build_object('name', 'smoke_in')),
        jsonb_build_array(jsonb_build_object('name', 'smoke_out')),
        jsonb_build_object('smoke', true),
        jsonb_build_object('smoke', true));

-- 清理：保证 smoke 不留痕，顺序按外键 / 唯一约束反推
DELETE FROM openlineage_events    WHERE event_id = '${EVENT_ID}';
DELETE FROM task_heartbeats       WHERE task_id = '${TASK_ID}';
DELETE FROM dataset_partitions    WHERE partition_id = '${PARTITION_ID}';
DELETE FROM ml_ready_datasets     WHERE output_uri = '${ML_OUTPUT_URI}';
DELETE FROM asset_profiles        WHERE profile_id = '${PROFILE_ID}';
DELETE FROM workflow_steps        WHERE workflow_namespace = 'robot-dh'
                                    AND workflow_name = '${WF_NAME}'
                                    AND step_name = '${STEP_NAME}';
DELETE FROM workflow_runs         WHERE workflow_namespace = 'robot-dh'
                                    AND workflow_name = '${WF_NAME}';
DELETE FROM qc_contract_runs      WHERE run_id = '${RUN_ID}';
DELETE FROM qc_contracts          WHERE contract_id = '${CONTRACT_ID}';

COMMIT;
EOF
)

printf '%s\n' "$SQL" | docker exec -i \
  -e PGPASSWORD="$ROBOT_DH_APP_PASSWORD" \
  robot-dh-postgres \
  psql -v ON_ERROR_STOP=1 -U "$ROBOT_DH_APP_USER" -d "$POSTGRES_DB" -P pager=off -f -

echo "v1.6 PostgreSQL smoke test passed (run_tag=$RUN_TAG)"
