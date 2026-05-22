-- v1.5 scale / benchmark / Argo workflow metadata schema.
-- 仅做 CREATE TABLE IF NOT EXISTS / CREATE INDEX IF NOT EXISTS。
-- 不修改 v1.3 / v1.4 已有表，不 DROP / ALTER 现有列。
-- 幂等，可重复执行。

BEGIN;

CREATE TABLE IF NOT EXISTS etl_perf_runs (
  id bigserial PRIMARY KEY,
  job_id text NOT NULL,
  run_id text,
  dataset_id text,
  version text,
  phase text NOT NULL,
  input_uri text,
  output_uri text,
  input_bytes bigint,
  output_bytes bigint,
  input_rows bigint,
  output_rows bigint,
  duration_sec double precision,
  download_duration_sec double precision,
  upload_duration_sec double precision,
  compute_duration_sec double precision,
  peak_memory_mb double precision,
  worker_id text,
  status text NOT NULL,
  error_message text,
  metrics_json jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS etl_shards (
  id bigserial PRIMARY KEY,
  plan_id text NOT NULL,
  shard_id int NOT NULL,
  shard_uri text,
  dataset_count int,
  input_bytes bigint,
  status text NOT NULL,
  assigned_worker text,
  started_at timestamptz,
  finished_at timestamptz,
  metrics_json jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (plan_id, shard_id)
);

CREATE TABLE IF NOT EXISTS benchmark_runs (
  id bigserial PRIMARY KEY,
  benchmark_id text NOT NULL UNIQUE,
  suite_name text NOT NULL,
  status text NOT NULL,
  started_at timestamptz,
  finished_at timestamptz,
  duration_sec double precision,
  metrics_json jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS benchmark_cases (
  id bigserial PRIMARY KEY,
  benchmark_id text NOT NULL,
  case_id text NOT NULL,
  dataset_uri text,
  mutation_type text,
  expected_status text,
  actual_status text,
  expected_failed_validators jsonb,
  actual_failed_validators jsonb,
  passed boolean,
  metrics_json jsonb,
  artifacts_uri text,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (benchmark_id, case_id)
);

CREATE TABLE IF NOT EXISTS argo_workflow_runs (
  id bigserial PRIMARY KEY,
  workflow_name text NOT NULL,
  workflow_uid text,
  workflow_namespace text,
  entrypoint text,
  status text,
  started_at timestamptz,
  finished_at timestamptz,
  duration_sec double precision,
  workflow_json jsonb,
  metrics_json jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS runtime_events (
  id bigserial PRIMARY KEY,
  event_id text NOT NULL UNIQUE,
  event_type text NOT NULL,
  source text,
  run_id text,
  job_id text,
  workflow_name text,
  dataset_id text,
  version text,
  payload_json jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_etl_perf_runs_dataset_version_phase_created_at
  ON etl_perf_runs (dataset_id, version, phase, created_at);

CREATE INDEX IF NOT EXISTS idx_etl_perf_runs_status_created_at
  ON etl_perf_runs (status, created_at);

CREATE INDEX IF NOT EXISTS idx_etl_shards_plan_id_status
  ON etl_shards (plan_id, status);

CREATE INDEX IF NOT EXISTS idx_benchmark_cases_benchmark_id_passed
  ON benchmark_cases (benchmark_id, passed);

CREATE INDEX IF NOT EXISTS idx_argo_workflow_runs_status_created_at
  ON argo_workflow_runs (status, created_at);

CREATE INDEX IF NOT EXISTS idx_runtime_events_event_type_created_at
  ON runtime_events (event_type, created_at);

-- 把新表的权限授予应用账号，与 001 迁移保持一致。
-- 应用账号名通过 GUC `robot_dh.app_user` 注入；若未设置则跳过授权，由后续维护操作补齐。
DO $$
DECLARE
  app_user text;
BEGIN
  BEGIN
    app_user := current_setting('robot_dh.app_user', true);
  EXCEPTION WHEN OTHERS THEN
    app_user := NULL;
  END;

  IF app_user IS NULL OR app_user = '' THEN
    RAISE NOTICE 'robot_dh.app_user GUC 未设置，跳过 v1.5 表的 GRANT，请稍后手动执行。';
    RETURN;
  END IF;

  EXECUTE format(
    'GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE etl_perf_runs, etl_shards, benchmark_runs, benchmark_cases, argo_workflow_runs, runtime_events TO %I',
    app_user
  );
  EXECUTE format(
    'GRANT USAGE, SELECT ON SEQUENCE etl_perf_runs_id_seq, etl_shards_id_seq, benchmark_runs_id_seq, benchmark_cases_id_seq, argo_workflow_runs_id_seq, runtime_events_id_seq TO %I',
    app_user
  );
END
$$;

COMMIT;
