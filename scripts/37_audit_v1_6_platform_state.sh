#!/usr/bin/env bash
set -euo pipefail

# v1.6 平台状态审计（read-only）。
#
# 输出：
#   1. PostgreSQL row count：v1.3 / v1.4 / v1.5 / v1.6 所有核心表
#   2. MinIO 各 bucket 占用与对象数（robot-datasets / robot-lake / robot-dh-artifacts / robot-dh-backups）
#   3. JSON 报告：/data/robot-dh/logs/v1_6_platform_state_YYYYmmdd_HHMMSS.json
#   4. 终端 human-readable summary
#
# 安全约束：
#   - 不修改任何数据
#   - 不暴露密码到 stdout / 日志
#   - 容器未启动时优雅降级

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
ENV_FILE="$PROJECT_DIR/.env"
LOG_ROOT="/data/robot-dh/logs"
TIMESTAMP=$(date -u +%Y%m%d_%H%M%S)
OUT_FILE="$LOG_ROOT/v1_6_platform_state_${TIMESTAMP}.json"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE not found. Run ./scripts/03_generate_env.sh first." >&2
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker is not installed." >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 is required to render JSON / summary." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

: "${POSTGRES_DB:?POSTGRES_DB not set in .env}"
: "${POSTGRES_USER:?POSTGRES_USER not set in .env}"
: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD not set in .env}"

ROBOT_DH_DATA_BUCKET="${ROBOT_DH_DATA_BUCKET:-robot-datasets}"
ROBOT_DH_ARTIFACT_BUCKET="${ROBOT_DH_ARTIFACT_BUCKET:-robot-dh-artifacts}"
ROBOT_DH_BACKUP_BUCKET="${ROBOT_DH_BACKUP_BUCKET:-robot-dh-backups}"
ROBOT_DH_LAKE_BUCKET="${ROBOT_DH_LAKE_BUCKET:-robot-lake}"

BUCKETS=(
  "$ROBOT_DH_DATA_BUCKET"
  "$ROBOT_DH_LAKE_BUCKET"
  "$ROBOT_DH_ARTIFACT_BUCKET"
  "$ROBOT_DH_BACKUP_BUCKET"
)

# v1.3 表名兜底集合（实际由主项目 robot-data-harness 写入；本仓库只读不建表）
V13_TABLES=(
  datasets
  runs
  gate_results
  metrics
)
V14_TABLES=(
  lake_assets
  etl_jobs
  lineage_edges
  dataset_versions
  quality_snapshots
)
V15_TABLES=(
  etl_perf_runs
  etl_shards
  benchmark_runs
  benchmark_cases
  argo_workflow_runs
  runtime_events
)
V16_TABLES=(
  qc_contracts
  qc_contract_runs
  workflow_runs
  workflow_steps
  asset_profiles
  ml_ready_datasets
  dataset_partitions
  task_heartbeats
  openlineage_events
)

mkdir -p "$LOG_ROOT"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

PG_ROWS_JSON="$TMP_DIR/pg_rows.json"
MINIO_JSON="$TMP_DIR/minio.json"

# 1) PostgreSQL row count
#
# 实现说明：
#   PostgreSQL 在 plan 阶段就会解析 FROM 列表，即使 to_regclass(...) IS NULL 的 CASE 分支不被执行，
#   它仍会尝试解析 FROM <table>，对于不存在的表会立刻 "relation does not exist" 报错。
#   所以这里采用 PL/pgSQL DO 块 + EXECUTE format(...) 动态执行 SELECT count(*)，
#   并把结果累加到 temp table 中；最后 SELECT row_to_json(t) 输出。
#
# 整个流程：
#   1. 在一个 DO 块里建 TEMP TABLE _v1_6_audit_counts(version,table,row_count)
#   2. 对每张目标表用 to_regclass 探测存在性，存在则 EXECUTE format(...) 计数
#   3. SELECT row_to_json(t) FROM 这张 temp table 输出
build_pg_sql_pairs() {
  local v t
  for t in "${V13_TABLES[@]}"; do echo "v1.3 $t"; done
  for t in "${V14_TABLES[@]}"; do echo "v1.4 $t"; done
  for t in "${V15_TABLES[@]}"; do echo "v1.5 $t"; done
  for t in "${V16_TABLES[@]}"; do echo "v1.6 $t"; done
}

# DO 块循环：拼接 pairs 列表为 PL/pgSQL VALUES 列表，避免 plan-time relation check。
DO_VALUES=""
while read -r ver tbl; do
  [[ -z "$ver" || -z "$tbl" ]] && continue
  if [[ -n "$DO_VALUES" ]]; then
    DO_VALUES+=",
"
  fi
  DO_VALUES+="('${ver}','${tbl}')"
done < <(build_pg_sql_pairs)

PG_SQL_WRAPPED=$(cat <<EOF
DROP TABLE IF EXISTS _v1_6_audit_counts;
CREATE TEMP TABLE _v1_6_audit_counts (version text, table_name text, row_count bigint);

DO \$\$
DECLARE
  r record;
  cnt bigint;
BEGIN
  FOR r IN
    SELECT * FROM (VALUES
${DO_VALUES}
    ) AS v(version, tbl)
  LOOP
    IF to_regclass('public.' || r.tbl) IS NULL THEN
      INSERT INTO _v1_6_audit_counts(version, table_name, row_count) VALUES (r.version, r.tbl, -1);
    ELSE
      EXECUTE format('SELECT count(*)::bigint FROM %I', r.tbl) INTO cnt;
      INSERT INTO _v1_6_audit_counts(version, table_name, row_count) VALUES (r.version, r.tbl, cnt);
    END IF;
  END LOOP;
END
\$\$;

SELECT row_to_json(t) FROM (
  SELECT version, table_name, row_count
    FROM _v1_6_audit_counts
   ORDER BY version, table_name
) t;
EOF
)

if docker inspect robot-dh-postgres >/dev/null 2>&1; then
  if printf '%s\n' "$PG_SQL_WRAPPED" | docker exec -i \
      -e PGPASSWORD="$POSTGRES_PASSWORD" \
      robot-dh-postgres \
      psql -At -U "$POSTGRES_USER" -d "$POSTGRES_DB" -P pager=off -f - > "$PG_ROWS_JSON.raw" 2>/dev/null; then
    python3 - "$PG_ROWS_JSON.raw" "$PG_ROWS_JSON" <<'PY'
import json, sys
src, dst = sys.argv[1], sys.argv[2]
rows = []
with open(src, "r", encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        # 跳过 DO 块的输出消息 / 状态行
        if not line.startswith("{"):
            continue
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError:
            continue
with open(dst, "w", encoding="utf-8") as f:
    json.dump(rows, f, ensure_ascii=False, indent=2)
PY
  else
    echo '[]' > "$PG_ROWS_JSON"
  fi
else
  echo '[]' > "$PG_ROWS_JSON"
fi

# 2) MinIO bucket 占用 / 对象数
#    用 MC_HOST 环境变量直接注入凭据，避免 mc alias set 步骤；
#    minio/mc:latest 是 distroless，容器内不能用 grep / awk，全部解析放到 host python。
collect_minio() {
  local out="$1"
  if ! docker inspect robot-dh-minio >/dev/null 2>&1; then
    echo '[]' > "$out"
    return 0
  fi

  local agg=()
  local raw_dir="$TMP_DIR/minio"
  mkdir -p "$raw_dir"

  for bucket in "${BUCKETS[@]}"; do
    local du_out="$raw_dir/${bucket}.du.jsonl"
    if docker run --rm \
        --network robot-dh-net \
        -e "MC_HOST_local=http://${MINIO_ROOT_USER}:${MINIO_ROOT_PASSWORD}@robot-dh-minio:9000" \
        minio/mc:latest \
        du --recursive --json "local/$bucket" > "$du_out" 2>/dev/null; then
      :
    else
      : > "$du_out"
    fi
  done

  python3 - "$raw_dir" "$out" <<'PY'
import json, os, sys
raw_dir, out_path = sys.argv[1], sys.argv[2]
result = []
for fname in sorted(os.listdir(raw_dir)):
    if not fname.endswith(".du.jsonl"):
        continue
    bucket = fname[:-len(".du.jsonl")]
    total_size = 0
    total_objs = 0
    reachable = False
    with open(os.path.join(raw_dir, fname), "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            reachable = True
            size = row.get("size") or row.get("totalSize") or 0
            objs = row.get("objects") or row.get("objectCount") or 0
            try:
                total_size = max(total_size, int(size))
                total_objs = max(total_objs, int(objs))
            except (TypeError, ValueError):
                pass
    result.append({
        "bucket": bucket,
        "reachable": reachable,
        "size_bytes": total_size,
        "object_count": total_objs,
    })
with open(out_path, "w", encoding="utf-8") as f:
    json.dump(result, f, ensure_ascii=False, indent=2)
PY
}

collect_minio "$MINIO_JSON"

# 3) 汇总 -> JSON + 终端 summary
python3 - "$PG_ROWS_JSON" "$MINIO_JSON" "$OUT_FILE" "$TIMESTAMP" <<'PY'
import json, sys
from datetime import datetime, timezone

pg_path, minio_path, out_path, ts = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

with open(pg_path, "r", encoding="utf-8") as f:
    pg_rows = json.load(f)
with open(minio_path, "r", encoding="utf-8") as f:
    minio_rows = json.load(f)

def gib(n):
    try:
        return round(int(n) / 1024 / 1024 / 1024, 3)
    except (TypeError, ValueError):
        return None

by_version: dict[str, list] = {}
for row in pg_rows:
    by_version.setdefault(row["version"], []).append({
        "table_name": row["table_name"],
        "row_count": row["row_count"],
        "exists": row["row_count"] >= 0,
    })

minio_total = sum((b.get("size_bytes") or 0) for b in minio_rows)

report = {
    "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "platform_version": "v1.6",
    "postgres_tables": by_version,
    "minio_buckets": minio_rows,
    "minio_total_bytes": minio_total,
    "minio_total_gib": gib(minio_total),
}

with open(out_path, "w", encoding="utf-8") as f:
    json.dump(report, f, ensure_ascii=False, indent=2)

print("=" * 78)
print(f"v1.6 Platform State Audit  (generated_at={report['generated_at']})")
print("=" * 78)

for version in ("v1.3", "v1.4", "v1.5", "v1.6"):
    rows = by_version.get(version, [])
    if not rows:
        continue
    print()
    print(f"-- PostgreSQL {version} tables --")
    print(f"  {'TABLE':<28} {'EXISTS':>7} {'ROW_COUNT':>14}")
    for r in sorted(rows, key=lambda x: x["table_name"]):
        rc = r["row_count"] if r["exists"] else "missing"
        print(f"  {r['table_name']:<28} {str(r['exists']):>7} {str(rc):>14}")

print()
print("-- MinIO buckets --")
if minio_rows:
    print(f"  {'BUCKET':<30} {'REACH':>5} {'SIZE_GiB':>10} {'OBJECTS':>10}")
    for b in minio_rows:
        size_gib = gib(b.get("size_bytes"))
        print(
            f"  {b.get('bucket','?'):<30} "
            f"{str(b.get('reachable')):>5} "
            f"{(size_gib if size_gib is not None else '-'):>10} "
            f"{b.get('object_count','-'):>10}"
        )
    print(f"  {'TOTAL':<30} {'-':>5} {(gib(minio_total) or '-'):>10}")
else:
    print("  (MinIO 容器未启动或不可达；跳过)")

print()
print(f"JSON report: {out_path}")
PY

echo
echo "v1.6 platform state audit finished. Report: $OUT_FILE"
