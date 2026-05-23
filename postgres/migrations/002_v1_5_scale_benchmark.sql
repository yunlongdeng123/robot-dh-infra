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

-- etl_shards：scale ETL 的分片记录。
-- shard_id 是 'plan-<ts>-<hash>::shard-<idx>' 复合字符串，与主项目 SQLAlchemy 模型一致；
-- shard_index 是 0-based 的分片序号（int），用于按序汇总 / 排错。
-- shard_uri / assigned_worker 是 v1.5 早期遗留字段，主项目当前不写也不读，保留兼容，禁止用于新逻辑。
CREATE TABLE IF NOT EXISTS etl_shards (
  id bigserial PRIMARY KEY,
  plan_id text NOT NULL,
  shard_id text NOT NULL,
  shard_index int,
  shard_uri text,
  dataset_count int,
  input_bytes bigint,
  status text NOT NULL,
  assigned_worker text,
  started_at timestamptz,
  finished_at timestamptz,
  duration_sec double precision,
  succeeded int,
  failed int,
  skipped int,
  summary_uri text,
  error_message text,
  metrics_json jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (plan_id, shard_id)
);

-- benchmark_runs：与主项目 `robot-data-harness` benchmark workflow 对齐。
-- 旧字段 status / duration_sec 仍保留；passed / failed / mismatched 是 case 级聚合计数。
CREATE TABLE IF NOT EXISTS benchmark_runs (
  id bigserial PRIMARY KEY,
  benchmark_id text NOT NULL UNIQUE,
  suite_name text NOT NULL,
  suite_path text,
  status text NOT NULL,
  started_at timestamptz,
  finished_at timestamptz,
  duration_sec double precision,
  total_cases int,
  passed int,
  failed int,
  mismatched int,
  report_uri text,
  metrics_json jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- benchmark_cases：与主项目 SQLAlchemy 模型对齐。
-- match 语义：
--   TRUE  = actual_status 与 expected_status 匹配，
--           且 expected_failed_validators 为空或是 actual_failed_validators 的子集
--   FALSE = 不匹配或 case 运行异常
--   NULL  = 未知 / 历史数据未回填
-- 兼容字段：
--   passed       = match 上线前的旧布尔列，主项目改写 match，exporter 按 COALESCE(match, passed) 聚合
--   mutation_type = mutation 上线前的旧 text 列，主项目改写 mutation，exporter 按 COALESCE(mutation, mutation_type) 读
CREATE TABLE IF NOT EXISTS benchmark_cases (
  id bigserial PRIMARY KEY,
  benchmark_id text NOT NULL,
  case_id text NOT NULL,
  dataset_uri text,
  mutation_type text,
  mutation text,
  expected_status text,
  actual_status text,
  expected_failed_validators jsonb,
  actual_failed_validators jsonb,
  passed boolean,
  match boolean,
  duration_sec double precision,
  error_message text,
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

CREATE INDEX IF NOT EXISTS idx_benchmark_cases_benchmark_id_match
  ON benchmark_cases (benchmark_id, match);

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
