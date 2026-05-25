#!/usr/bin/env bash
set -euo pipefail

# v1.6 workflow metadata 报告（read-only）。
#
# 数据源（任意一张缺失都优雅降级）：
#   - workflow_runs           v1.6 通用 workflow run
#   - workflow_steps          v1.6 单 step 元数据
#   - argo_workflow_runs      v1.5 Argo 同步快照
#   - runtime_events          v1.5 通用事件总线
#
# 输出：
#   - 终端：最近 20 个 workflow / 失败 step / runtime events 摘要
#   - Markdown：/data/robot-dh/logs/v1_6_workflow_metadata_report_YYYYmmdd_HHMMSS.md

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
ENV_FILE="$PROJECT_DIR/.env"
LOG_ROOT="/data/robot-dh/logs"
TIMESTAMP=$(date -u +%Y%m%d_%H%M%S)
OUT_FILE="$LOG_ROOT/v1_6_workflow_metadata_report_${TIMESTAMP}.md"

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

# 通过 to_regclass 判断表存在；不存在则跳过对应章节，不报错
table_exists() {
  local table="$1"
  local out
  out=$(pg_query "SELECT to_regclass('public.${table}') IS NOT NULL;")
  [[ "${out//[[:space:]]/}" == "t" ]]
}

WF_RUNS_EXISTS=0
WF_STEPS_EXISTS=0
ARGO_RUNS_EXISTS=0
RUNTIME_EVENTS_EXISTS=0

table_exists workflow_runs       && WF_RUNS_EXISTS=1
table_exists workflow_steps      && WF_STEPS_EXISTS=1
table_exists argo_workflow_runs  && ARGO_RUNS_EXISTS=1
table_exists runtime_events      && RUNTIME_EVENTS_EXISTS=1

write_md() {
  # set -u 下空参会报 unbound variable，所以默认为空字符串
  printf '%s\n' "${1:-}" >> "$OUT_FILE"
}

: > "$OUT_FILE"

write_md "# v1.6 Workflow Metadata Report"
write_md
write_md "- generated_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
write_md "- database: ${POSTGRES_DB}"
write_md
write_md "数据源表存在性："
write_md
write_md "| 表 | 状态 |"
write_md "|----|------|"
write_md "| workflow_runs       | $([[ $WF_RUNS_EXISTS -eq 1 ]] && echo 存在 || echo 缺失) |"
write_md "| workflow_steps      | $([[ $WF_STEPS_EXISTS -eq 1 ]] && echo 存在 || echo 缺失) |"
write_md "| argo_workflow_runs  | $([[ $ARGO_RUNS_EXISTS -eq 1 ]] && echo 存在 || echo 缺失) |"
write_md "| runtime_events      | $([[ $RUNTIME_EVENTS_EXISTS -eq 1 ]] && echo 存在 || echo 缺失) |"
write_md

# 1) 最近 20 个 workflow
write_md "## 1. 最近 20 个 workflow"
write_md
write_md "合并 workflow_runs 与 argo_workflow_runs：按 finished_at desc nulls last，再按 created_at desc。"
write_md
write_md "| source | namespace | name | status | started_at | finished_at | duration_sec |"
write_md "|--------|-----------|------|--------|-----------|-------------|--------------|"

UNION_PARTS=()
if [[ $WF_RUNS_EXISTS -eq 1 ]]; then
  UNION_PARTS+=("SELECT 'workflow_runs' AS source, COALESCE(workflow_namespace,'') AS namespace, workflow_name AS name, COALESCE(status,'') AS status, started_at, finished_at, duration_sec, created_at FROM workflow_runs")
fi
if [[ $ARGO_RUNS_EXISTS -eq 1 ]]; then
  UNION_PARTS+=("SELECT 'argo_workflow_runs' AS source, COALESCE(workflow_namespace,'') AS namespace, workflow_name AS name, COALESCE(status,'') AS status, started_at, finished_at, duration_sec, created_at FROM argo_workflow_runs")
fi

RECENT_ROWS=""
if (( ${#UNION_PARTS[@]} > 0 )); then
  UNION_SQL=$(printf ' UNION ALL %s' "${UNION_PARTS[@]}")
  UNION_SQL="${UNION_SQL# UNION ALL }"
  SQL="SELECT source, namespace, name, status,
              to_char(started_at  AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'),
              to_char(finished_at AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'),
              COALESCE(to_char(duration_sec, 'FM999990.000'), '')
         FROM (${UNION_SQL}) u
        ORDER BY finished_at DESC NULLS LAST, created_at DESC
        LIMIT 20;"
  RECENT_ROWS=$(pg_query "$SQL" || true)
fi

if [[ -z "$RECENT_ROWS" ]]; then
  write_md "| _无数据_ | | | | | | |"
else
  while IFS='|' read -r src ns name status started finished dur; do
    [[ -z "$src" ]] && continue
    write_md "| ${src} | ${ns} | ${name} | ${status} | ${started} | ${finished} | ${dur} |"
  done <<<"$RECENT_ROWS"
fi
write_md

# 2) 失败 step 分布
write_md "## 2. 失败 step 分布"
write_md
write_md "phase 命中 Failed / Error / Aborted / Timeout 视为失败；按 (workflow_name, template_name, phase) 聚合。"
write_md
write_md "| workflow_name | template_name | phase | count | latest_finished_at |"
write_md "|---------------|---------------|-------|-------|--------------------|"

FAIL_ROWS=""
if [[ $WF_STEPS_EXISTS -eq 1 ]]; then
  SQL="SELECT workflow_name,
              COALESCE(template_name,'') AS template_name,
              COALESCE(phase,'') AS phase,
              count(*) AS cnt,
              to_char(max(finished_at) AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')
         FROM workflow_steps
        WHERE phase IN ('Failed','Error','Aborted','Timeout','Failed/Retry')
        GROUP BY workflow_name, template_name, phase
        ORDER BY cnt DESC, workflow_name
        LIMIT 50;"
  FAIL_ROWS=$(pg_query "$SQL" || true)
fi

if [[ -z "$FAIL_ROWS" ]]; then
  write_md "| _无失败 step_ | | | | |"
else
  while IFS='|' read -r wf tpl phase cnt latest; do
    [[ -z "$wf" ]] && continue
    write_md "| ${wf} | ${tpl} | ${phase} | ${cnt} | ${latest} |"
  done <<<"$FAIL_ROWS"
fi
write_md

# 3) 各 dataset_family / version 的 step phase 分布（v1.6 新增的多源维度）
write_md "## 3. 多源 step phase 分布"
write_md
write_md "按 (dataset_family, dataset_id, version, phase) 聚合 workflow_steps，便于看出 normalize / feature 哪一类数据 stuck。"
write_md
write_md "| dataset_family | dataset_id | version | phase | count |"
write_md "|----------------|-----------|---------|-------|-------|"

FAMILY_ROWS=""
if [[ $WF_STEPS_EXISTS -eq 1 ]]; then
  SQL="SELECT COALESCE(dataset_family,'-') AS dataset_family,
              COALESCE(dataset_id,'-')     AS dataset_id,
              COALESCE(version,'-')        AS version,
              COALESCE(phase,'-')          AS phase,
              count(*) AS cnt
         FROM workflow_steps
        GROUP BY dataset_family, dataset_id, version, phase
        ORDER BY dataset_family, dataset_id, version, phase
        LIMIT 100;"
  FAMILY_ROWS=$(pg_query "$SQL" || true)
fi

if [[ -z "$FAMILY_ROWS" ]]; then
  write_md "| _无数据_ | | | | |"
else
  while IFS='|' read -r fam ds ver phase cnt; do
    [[ -z "$fam$ds$ver$phase$cnt" ]] && continue
    write_md "| ${fam} | ${ds} | ${ver} | ${phase} | ${cnt} |"
  done <<<"$FAMILY_ROWS"
fi
write_md

# 4) runtime_events 最近 20 条
write_md "## 4. runtime_events 最近 20 条"
write_md
write_md "| event_type | source | workflow_name | dataset_id | version | created_at |"
write_md "|------------|--------|---------------|-----------|---------|-----------|"

RT_ROWS=""
if [[ $RUNTIME_EVENTS_EXISTS -eq 1 ]]; then
  SQL="SELECT COALESCE(event_type,'-'),
              COALESCE(source,'-'),
              COALESCE(workflow_name,'-'),
              COALESCE(dataset_id,'-'),
              COALESCE(version,'-'),
              to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')
         FROM runtime_events
        ORDER BY created_at DESC
        LIMIT 20;"
  RT_ROWS=$(pg_query "$SQL" || true)
fi

if [[ -z "$RT_ROWS" ]]; then
  write_md "| _无事件_ | | | | | |"
else
  while IFS='|' read -r etype src wfname dsid ver ts; do
    [[ -z "$etype$src$wfname$dsid$ver$ts" ]] && continue
    write_md "| ${etype} | ${src} | ${wfname} | ${dsid} | ${ver} | ${ts} |"
  done <<<"$RT_ROWS"
fi
write_md

# 终端 summary
echo "v1.6 workflow metadata report -> $OUT_FILE"
echo
echo "Sources:"
echo "  workflow_runs:       $WF_RUNS_EXISTS"
echo "  workflow_steps:      $WF_STEPS_EXISTS"
echo "  argo_workflow_runs:  $ARGO_RUNS_EXISTS"
echo "  runtime_events:      $RUNTIME_EVENTS_EXISTS"
echo
echo "Markdown sections written: 最近 workflow / 失败 step / 多源 step phase / runtime_events"
