-- v1.5 etl_shards 对齐迁移：把 002 创建的旧 schema 升级到主项目 SQLAlchemy 模型。
-- 用于已经跑过 002 的环境；全新环境直接由 002 创建对齐后的表，无需再跑此文件。
-- 全部步骤幂等，可重复执行。
--
-- 变更要点：
--   1. shard_id: int NOT NULL -> text NOT NULL
--      主项目实际写入的是 'plan-<ts>-<hash>::shard-<idx>' 复合字符串。
--      旧表如果是空的（soft-mode 下根本没成功写入过 int），转换零数据风险。
--   2. 新增 7 列：shard_index / duration_sec / succeeded / failed / skipped / summary_uri / error_message。
--   3. shard_uri / assigned_worker 保留兼容，不删除。
--   4. UNIQUE (plan_id, shard_id) 维持不变（列类型变更不会破坏 unique 约束）。

BEGIN;

-- 兜底：如果 etl_shards 尚不存在，直接跳过本迁移，由 002 负责建表。
DO $$
BEGIN
  IF to_regclass('public.etl_shards') IS NULL THEN
    RAISE NOTICE 'etl_shards 不存在，跳过 003 对齐迁移；请先跑 ./scripts/29_pg_apply_v1_5_schema.sh。';
    RETURN;
  END IF;
END
$$;

-- 1. shard_id 类型从 int 改为 text（如果当前已经是 text，跳过）。
DO $$
DECLARE
  current_type text;
  row_count bigint;
BEGIN
  IF to_regclass('public.etl_shards') IS NULL THEN
    RETURN;
  END IF;

  SELECT data_type
    INTO current_type
  FROM information_schema.columns
  WHERE table_schema = current_schema()
    AND table_name = 'etl_shards'
    AND column_name = 'shard_id';

  IF current_type IS NULL THEN
    RAISE EXCEPTION 'etl_shards.shard_id 列缺失，schema 已被外部破坏，拒绝继续。';
  END IF;

  IF current_type = 'text' THEN
    RAISE NOTICE 'etl_shards.shard_id 已经是 text 类型，跳过类型转换。';
    RETURN;
  END IF;

  -- 升级前打印一行计数，方便审计；soft-mode 期间几乎都是 0。
  EXECUTE 'SELECT count(*) FROM etl_shards' INTO row_count;
  RAISE NOTICE 'etl_shards.shard_id 类型转换 % -> text，当前行数 %', current_type, row_count;

  EXECUTE 'ALTER TABLE etl_shards ALTER COLUMN shard_id TYPE text USING shard_id::text';
END
$$;

-- 2. 补齐主项目模型需要的列（每列单独 ADD IF NOT EXISTS，确保幂等）。
DO $$
BEGIN
  IF to_regclass('public.etl_shards') IS NULL THEN
    RETURN;
  END IF;

  EXECUTE 'ALTER TABLE etl_shards ADD COLUMN IF NOT EXISTS shard_index   int';
  EXECUTE 'ALTER TABLE etl_shards ADD COLUMN IF NOT EXISTS duration_sec  double precision';
  EXECUTE 'ALTER TABLE etl_shards ADD COLUMN IF NOT EXISTS succeeded     int';
  EXECUTE 'ALTER TABLE etl_shards ADD COLUMN IF NOT EXISTS failed        int';
  EXECUTE 'ALTER TABLE etl_shards ADD COLUMN IF NOT EXISTS skipped       int';
  EXECUTE 'ALTER TABLE etl_shards ADD COLUMN IF NOT EXISTS summary_uri   text';
  EXECUTE 'ALTER TABLE etl_shards ADD COLUMN IF NOT EXISTS error_message text';
END
$$;

-- 3. 给应用账号补 GRANT，与 002 末尾的 DO 块对称；GUC 由 admin 脚本注入。
DO $$
DECLARE
  app_user text;
BEGIN
  IF to_regclass('public.etl_shards') IS NULL THEN
    RETURN;
  END IF;

  BEGIN
    app_user := current_setting('robot_dh.app_user', true);
  EXCEPTION WHEN OTHERS THEN
    app_user := NULL;
  END;

  IF app_user IS NULL OR app_user = '' THEN
    RAISE NOTICE 'robot_dh.app_user GUC 未设置，跳过 etl_shards 的 GRANT，请稍后手动执行。';
    RETURN;
  END IF;

  EXECUTE format(
    'GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE etl_shards TO %I',
    app_user
  );
  EXECUTE format(
    'GRANT USAGE, SELECT ON SEQUENCE etl_shards_id_seq TO %I',
    app_user
  );
END
$$;

COMMIT;
