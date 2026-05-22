BEGIN;

CREATE TABLE IF NOT EXISTS lake_assets (
  id bigserial PRIMARY KEY,
  dataset_id text NOT NULL,
  version text NOT NULL,
  layer text NOT NULL,
  asset_type text NOT NULL,
  uri text NOT NULL UNIQUE,
  format text,
  size_bytes bigint,
  row_count bigint,
  checksum text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS etl_jobs (
  id bigserial PRIMARY KEY,
  job_id text NOT NULL UNIQUE,
  job_type text NOT NULL,
  input_uri text,
  output_uri text,
  status text NOT NULL,
  started_at timestamptz,
  finished_at timestamptz,
  duration_sec double precision,
  error_message text,
  metrics_json jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS lineage_edges (
  id bigserial PRIMARY KEY,
  source_uri text NOT NULL,
  target_uri text NOT NULL,
  job_id text NOT NULL,
  job_type text NOT NULL,
  run_id text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS dataset_versions (
  id bigserial PRIMARY KEY,
  dataset_id text NOT NULL,
  version text NOT NULL,
  raw_uri text,
  ods_uri text,
  dwd_uri text,
  status text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (dataset_id, version)
);

CREATE TABLE IF NOT EXISTS quality_snapshots (
  id bigserial PRIMARY KEY,
  dataset_id text NOT NULL,
  version text NOT NULL,
  run_id text,
  quality_status text,
  quality_score double precision,
  metrics_json jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_lake_assets_dataset_version_layer
  ON lake_assets (dataset_id, version, layer);

CREATE INDEX IF NOT EXISTS idx_etl_jobs_job_type_status_created_at
  ON etl_jobs (job_type, status, created_at);

CREATE INDEX IF NOT EXISTS idx_lineage_edges_source_uri
  ON lineage_edges (source_uri);

CREATE INDEX IF NOT EXISTS idx_lineage_edges_target_uri
  ON lineage_edges (target_uri);

CREATE INDEX IF NOT EXISTS idx_quality_snapshots_dataset_version_created_at
  ON quality_snapshots (dataset_id, version, created_at);

CREATE OR REPLACE FUNCTION set_row_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger WHERE tgname = 'trg_lake_assets_updated_at'
  ) THEN
    CREATE TRIGGER trg_lake_assets_updated_at
    BEFORE UPDATE ON lake_assets
    FOR EACH ROW
    EXECUTE FUNCTION set_row_updated_at();
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger WHERE tgname = 'trg_dataset_versions_updated_at'
  ) THEN
    CREATE TRIGGER trg_dataset_versions_updated_at
    BEFORE UPDATE ON dataset_versions
    FOR EACH ROW
    EXECUTE FUNCTION set_row_updated_at();
  END IF;
END
$$;

COMMIT;
