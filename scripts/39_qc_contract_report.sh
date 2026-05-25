#!/usr/bin/env bash
set -euo pipefail

# v1.6 QC contract 报告（read-only）。
#
# 输出：
#   - 按 dataset_family 聚合 qc_contract_runs 的 pass / warn / fail 计数
#   - 列出最近 20 条 qc_contract_runs
#   - 列出所有 enabled qc_contracts
#   - Markdown：/data/robot-dh/logs/v1_6_qc_contract_report_YYYYmmdd_HHMMSS.md
#
# 兼容：
#   - 表为空：输出空报告，不失败
#   - 表缺失：输出 "缺失" 标记，不失败

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
ENV_FILE="$PROJECT_DIR/.env"
LOG_ROOT="/data/robot-dh/logs"
TIMESTAMP=$(date -u +%Y%m%d_%H%M%S)
OUT_FILE="$LOG_ROOT/v1_6_qc_contract_report_${TIMESTAMP}.md"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE not found." >&2
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker is not installed." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

: "${POSTGRES_DB:?POSTGRES_DB not set in .env}"
: "${POSTGRES_USER:?POSTGRES_USER not set in .env}"
: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD not set in .env}"

if ! docker inspect robot-dh-postgres >/dev/null 2>&1; then
  echo "ERROR: PostgreSQL container robot-dh-postgres is not available." >&2
  exit 1
fi

mkdir -p "$LOG_ROOT"

pg_query() {
  local sql="$1"
  printf '%s\n' "$sql" | docker exec -i \
    -e PGPASSWORD="$POSTGRES_PASSWORD" \
    robot-dh-postgres \
    psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -P pager=off -A -F'|' --tuples-only -f -
}

table_exists() {
  local table="$1"
  local out
  out=$(pg_query "SELECT to_regclass('public.${table}') IS NOT NULL;")
  [[ "${out//[[:space:]]/}" == "t" ]]
}

CONTRACTS_EXISTS=0
RUNS_EXISTS=0
table_exists qc_contracts     && CONTRACTS_EXISTS=1
table_exists qc_contract_runs && RUNS_EXISTS=1

: > "$OUT_FILE"
write_md() { printf '%s\n' "${1:-}" >> "$OUT_FILE"; }

write_md "# v1.6 QC Contract Report"
write_md
write_md "- generated_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
write_md "- database: ${POSTGRES_DB}"
write_md "- qc_contracts:     $([[ $CONTRACTS_EXISTS -eq 1 ]] && echo 存在 || echo 缺失)"
write_md "- qc_contract_runs: $([[ $RUNS_EXISTS -eq 1 ]] && echo 存在 || echo 缺失)"
write_md

# 1) dataset_family 维度的 pass / warn / fail
write_md "## 1. dataset_family 维度统计"
write_md
write_md "status 归一：pass/passed/success -> pass；warn/warning -> warn；fail/failed/error -> fail；其余落入 other。"
write_md
write_md "| dataset_family | pass | warn | fail | other | total |"
write_md "|----------------|------|------|------|-------|-------|"

FAMILY_ROWS=""
if [[ $RUNS_EXISTS -eq 1 ]]; then
  SQL="WITH normalized AS (
         SELECT COALESCE(dataset_family,'-') AS dataset_family,
                CASE
                  WHEN lower(status) IN ('pass','passed','success') THEN 'pass'
                  WHEN lower(status) IN ('warn','warning')          THEN 'warn'
                  WHEN lower(status) IN ('fail','failed','error')   THEN 'fail'
                  ELSE 'other'
                END AS norm_status
           FROM qc_contract_runs
       )
       SELECT dataset_family,
              count(*) FILTER (WHERE norm_status = 'pass'),
              count(*) FILTER (WHERE norm_status = 'warn'),
              count(*) FILTER (WHERE norm_status = 'fail'),
              count(*) FILTER (WHERE norm_status = 'other'),
              count(*)
         FROM normalized
        GROUP BY dataset_family
        ORDER BY dataset_family;"
  FAMILY_ROWS=$(pg_query "$SQL" || true)
fi

if [[ -z "$FAMILY_ROWS" ]]; then
  write_md "| _无数据_ | 0 | 0 | 0 | 0 | 0 |"
else
  while IFS='|' read -r fam p w f o t; do
    [[ -z "$fam$p$w$f$o$t" ]] && continue
    write_md "| ${fam} | ${p} | ${w} | ${f} | ${o} | ${t} |"
  done <<<"$FAMILY_ROWS"
fi
write_md

# 2) 最近 20 条 qc_contract_runs
write_md "## 2. 最近 20 条 qc_contract_runs"
write_md
write_md "| run_id | contract_id | dataset_family | dataset_id | version | status | duration_sec | created_at |"
write_md "|--------|-------------|----------------|-----------|---------|--------|--------------|-----------|"

RECENT_ROWS=""
if [[ $RUNS_EXISTS -eq 1 ]]; then
  SQL="SELECT run_id,
              contract_id,
              COALESCE(dataset_family,'-'),
              COALESCE(dataset_id,'-'),
              COALESCE(version,'-'),
              status,
              COALESCE(to_char(duration_sec, 'FM999990.000'), ''),
              to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')
         FROM qc_contract_runs
        ORDER BY created_at DESC
        LIMIT 20;"
  RECENT_ROWS=$(pg_query "$SQL" || true)
fi

if [[ -z "$RECENT_ROWS" ]]; then
  write_md "| _无数据_ | | | | | | | |"
else
  while IFS='|' read -r rid cid fam dsid ver st dur ts; do
    [[ -z "$rid$cid$fam$dsid$ver$st$dur$ts" ]] && continue
    write_md "| ${rid} | ${cid} | ${fam} | ${dsid} | ${ver} | ${st} | ${dur} | ${ts} |"
  done <<<"$RECENT_ROWS"
fi
write_md

# 3) enabled qc_contracts
write_md "## 3. 当前启用的 qc_contracts"
write_md
write_md "| contract_id | dataset_family | version | enabled | updated_at | description |"
write_md "|-------------|----------------|---------|---------|-----------|-------------|"

CONTRACT_ROWS=""
if [[ $CONTRACTS_EXISTS -eq 1 ]]; then
  SQL="SELECT contract_id, dataset_family, version, enabled,
              to_char(updated_at AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'),
              COALESCE(description,'-')
         FROM qc_contracts
        ORDER BY enabled DESC, dataset_family, contract_id
        LIMIT 100;"
  CONTRACT_ROWS=$(pg_query "$SQL" || true)
fi

if [[ -z "$CONTRACT_ROWS" ]]; then
  write_md "| _无 contract 登记_ | | | | | |"
else
  while IFS='|' read -r cid fam ver en ts desc; do
    [[ -z "$cid$fam$ver$en$ts$desc" ]] && continue
    # 单元格中的 | 转义，避免破坏 Markdown 表格
    desc_safe="${desc//|/\\|}"
    write_md "| ${cid} | ${fam} | ${ver} | ${en} | ${ts} | ${desc_safe} |"
  done <<<"$CONTRACT_ROWS"
fi
write_md

# 终端 summary
echo "v1.6 QC contract report -> $OUT_FILE"
echo
if [[ $CONTRACTS_EXISTS -eq 0 || $RUNS_EXISTS -eq 0 ]]; then
  echo "INFO: qc_contracts / qc_contract_runs 部分或全部缺失。先跑 ./scripts/35_pg_apply_v1_6_schema.sh。"
fi
