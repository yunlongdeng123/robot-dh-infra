#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
ENV_FILE="$PROJECT_DIR/.env"
RUN_ID="lake_smoke_$(date -u +%Y%m%d_%H%M%S)"
JOB_ID="job_$RUN_ID"
ASSET_URI="s3://robot-lake/tmp/$RUN_ID/smoke.parquet"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE not found. Run ./scripts/03_generate_env.sh first." >&2
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker is not installed." >&2
  exit 1
fi

if ! docker inspect robot-dh-postgres >/dev/null 2>&1; then
  echo "ERROR: PostgreSQL container robot-dh-postgres is not available. Run ./scripts/04_up.sh first." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

printf '%s\n' "DO \$\$" \
"DECLARE" \
"  missing_tables text;" \
"BEGIN" \
"  SELECT string_agg(name, ', ' ORDER BY name)" \
"    INTO missing_tables" \
"  FROM (VALUES" \
"    ('dataset_versions')," \
"    ('etl_jobs')," \
"    ('lake_assets')," \
"    ('lineage_edges')," \
"    ('quality_snapshots')" \
") AS required(name)" \
"  WHERE to_regclass('public.' || name) IS NULL;" \
"" \
"  IF missing_tables IS NOT NULL THEN" \
"    RAISE EXCEPTION 'Missing lake metadata tables: %', missing_tables;" \
"  END IF;" \
"END" \
"\$\$;" \
"" \
"BEGIN;" \
"INSERT INTO dataset_versions (dataset_id, version, raw_uri, ods_uri, dwd_uri, status)" \
"VALUES ('smoke_dataset', '$RUN_ID', 's3://robot-lake/raw/smoke_dataset/$RUN_ID/', 's3://robot-lake/ods/smoke_dataset/$RUN_ID/', 's3://robot-lake/dwd/smoke_dataset/$RUN_ID/', 'smoke_created');" \
"" \
"INSERT INTO lake_assets (dataset_id, version, layer, asset_type, uri, format, size_bytes, row_count, checksum)" \
"VALUES ('smoke_dataset', '$RUN_ID', 'raw', 'pose', '$ASSET_URI', 'parquet', 128, 1, 'smoke-checksum');" \
"" \
"INSERT INTO etl_jobs (job_id, job_type, input_uri, output_uri, status, started_at, finished_at, duration_sec, metrics_json)" \
"VALUES ('$JOB_ID', 'lake_smoke', 's3://robot-lake/raw/smoke_dataset/$RUN_ID/', '$ASSET_URI', 'success', now(), now(), 0.25, jsonb_build_object('rows', 1, 'smoke', true));" \
"" \
"INSERT INTO lineage_edges (source_uri, target_uri, job_id, job_type, run_id)" \
"VALUES ('s3://robot-lake/raw/smoke_dataset/$RUN_ID/', '$ASSET_URI', '$JOB_ID', 'lake_smoke', '$RUN_ID');" \
"" \
"INSERT INTO quality_snapshots (dataset_id, version, run_id, quality_status, quality_score, metrics_json)" \
"VALUES ('smoke_dataset', '$RUN_ID', '$RUN_ID', 'pass', 1.0, jsonb_build_object('missing', 0, 'smoke', true));" \
"" \
"DELETE FROM quality_snapshots WHERE run_id = '$RUN_ID';" \
"DELETE FROM lineage_edges WHERE run_id = '$RUN_ID';" \
"DELETE FROM etl_jobs WHERE job_id = '$JOB_ID';" \
"DELETE FROM lake_assets WHERE uri = '$ASSET_URI';" \
"DELETE FROM dataset_versions WHERE dataset_id = 'smoke_dataset' AND version = '$RUN_ID';" \
"COMMIT;" | docker exec -i \
  -e PGPASSWORD="$ROBOT_DH_APP_PASSWORD" \
  robot-dh-postgres \
  psql -v ON_ERROR_STOP=1 -U "$ROBOT_DH_APP_USER" -d "$POSTGRES_DB" -P pager=off -f -

echo "PostgreSQL lake smoke test passed for run_id=$RUN_ID"
