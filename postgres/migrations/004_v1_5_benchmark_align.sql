-- v1.5 benchmark_cases / benchmark_runs 对齐迁移。
-- 用于已经跑过 002 的环境；全新环境直接由 002 创建对齐后的表，无需再跑此文件。
-- 全部步骤幂等，可重复执行。
--
-- 变更要点：
--   benchmark_cases:
--     ADD COLUMN IF NOT EXISTS mutation        text
--     ADD COLUMN IF NOT EXISTS match           boolean
--     ADD COLUMN IF NOT EXISTS duration_sec    double precision
--     ADD COLUMN IF NOT EXISTS error_message   text
--     回填：match <- passed (当 match IS NULL)、mutation <- mutation_type (当 mutation IS NULL)
--   benchmark_runs:
--     ADD COLUMN IF NOT EXISTS suite_path    text
--     ADD COLUMN IF NOT EXISTS total_cases   int
--     ADD COLUMN IF NOT EXISTS passed        int
--     ADD COLUMN IF NOT EXISTS failed        int
--     ADD COLUMN IF NOT EXISTS mismatched    int
--     ADD COLUMN IF NOT EXISTS report_uri    text
--   兼容字段 passed (boolean) / mutation_type (text) 在 benchmark_cases 中保留不删除：
--     主项目改写 match / mutation，exporter 用 COALESCE(match, passed) / COALESCE(mutation, mutation_type) 聚合。

BEGIN;

-- 兜底：表必须存在；若 002 还没跑，提示后退出（DO 块里 RETURN 即可，外层 COMMIT 不受影响）。
DO $$
BEGIN
  IF to_regclass('public.benchmark_cases') IS NULL
     OR to_regclass('public.benchmark_runs') IS NULL THEN
    RAISE NOTICE 'benchmark_cases / benchmark_runs 不存在，跳过 004 对齐迁移；请先跑 ./scripts/29_pg_apply_v1_5_schema.sh。';
    RETURN;
  END IF;
END
$$;

DO $$
BEGIN
  IF to_regclass('public.benchmark_cases') IS NULL
     OR to_regclass('public.benchmark_runs') IS NULL THEN
    RETURN;
  END IF;

  -- 1. benchmark_cases 补列
  EXECUTE 'ALTER TABLE benchmark_cases ADD COLUMN IF NOT EXISTS mutation      text';
  EXECUTE 'ALTER TABLE benchmark_cases ADD COLUMN IF NOT EXISTS match         boolean';
  EXECUTE 'ALTER TABLE benchmark_cases ADD COLUMN IF NOT EXISTS duration_sec  double precision';
  EXECUTE 'ALTER TABLE benchmark_cases ADD COLUMN IF NOT EXISTS error_message text';

  -- 2. benchmark_runs 补列
  EXECUTE 'ALTER TABLE benchmark_runs ADD COLUMN IF NOT EXISTS suite_path  text';
  EXECUTE 'ALTER TABLE benchmark_runs ADD COLUMN IF NOT EXISTS total_cases int';
  EXECUTE 'ALTER TABLE benchmark_runs ADD COLUMN IF NOT EXISTS passed      int';
  EXECUTE 'ALTER TABLE benchmark_runs ADD COLUMN IF NOT EXISTS failed      int';
  EXECUTE 'ALTER TABLE benchmark_runs ADD COLUMN IF NOT EXISTS mismatched  int';
  EXECUTE 'ALTER TABLE benchmark_runs ADD COLUMN IF NOT EXISTS report_uri  text';

  -- 3. 历史数据回填：把旧 passed / mutation_type 投影到新列（仅在新列 NULL 时回填，幂等）。
  EXECUTE 'UPDATE benchmark_cases
              SET match = passed
            WHERE match IS NULL
              AND passed IS NOT NULL';

  EXECUTE 'UPDATE benchmark_cases
              SET mutation = mutation_type
            WHERE mutation IS NULL
              AND mutation_type IS NOT NULL';

  -- 4. 索引：按 match 聚合的查询走新索引（passed 索引由 002 保留，旧报表照常）。
  EXECUTE 'CREATE INDEX IF NOT EXISTS idx_benchmark_cases_benchmark_id_match
             ON benchmark_cases (benchmark_id, match)';
END
$$;

-- 5. 给应用账号补 GRANT，与 002 / 003 末尾对称。
DO $$
DECLARE
  app_user text;
BEGIN
  IF to_regclass('public.benchmark_cases') IS NULL
     OR to_regclass('public.benchmark_runs') IS NULL THEN
    RETURN;
  END IF;

  BEGIN
    app_user := current_setting('robot_dh.app_user', true);
  EXCEPTION WHEN OTHERS THEN
    app_user := NULL;
  END;

  IF app_user IS NULL OR app_user = '' THEN
    RAISE NOTICE 'robot_dh.app_user GUC 未设置，跳过 benchmark_* 的 GRANT，请稍后手动执行。';
    RETURN;
  END IF;

  EXECUTE format(
    'GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE benchmark_cases, benchmark_runs TO %I',
    app_user
  );
  -- 序列 GRANT 在 002 已经做过；这里再 EXECUTE 一次幂等，避免新部署漏掉。
  EXECUTE format(
    'GRANT USAGE, SELECT ON SEQUENCE benchmark_cases_id_seq, benchmark_runs_id_seq TO %I',
    app_user
  );
END
$$;

COMMIT;
