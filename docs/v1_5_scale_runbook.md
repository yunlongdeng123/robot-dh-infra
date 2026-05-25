# robot-dh-infra v1.5 scale Runbook

本 runbook 描述 v1.5 升级后的运维操作流程，覆盖 30GB 级数据审计、MinIO 用量统计、生命周期策略、PostgreSQL v1.5 schema 应用，以及 Argo Workflows 远程访问 secret 准备。

## 1. v1.5 范围

v1.5 不变更服务进程，不安装新组件，只新增运维脚本与 PostgreSQL 元数据表：

- 存储风险检查与 `/dev/vdb` 迁移计划（脚本 25 / 26）
- scale30 数据审计与 MinIO 生命周期建议（脚本 27 / 28）
- PostgreSQL 新增 6 张表，记录 ETL 性能 / shard 计划 / benchmark / Argo workflow / 通用 runtime event（migration 002）
- 早期 v1.5 环境的 `etl_shards` 与 `benchmark_*` schema 对齐（migration 003 / 004，脚本 33 / 34）
- Argo Workflows 远程访问 Secret / ServiceAccount / RBAC / env 模板

> Argo Workflows 控制面（argo-server、workflow-controller）由 WSL/kind 项目部署，本仓库**不**安装 Argo。

## 2. 跑 30GB ETL 之前

按以下顺序检查，所有脚本均**只读**：

```bash
cd /opt/robot-dh-infra

./scripts/06_healthcheck.sh
./scripts/25_storage_pressure_report.sh
./scripts/27_audit_scale30_assets.sh
./scripts/28_minio_lifecycle_plan.sh
```

关注点：

- `25_storage_pressure_report.sh` 报告内容：
  - `root_filesystem.avail_bytes < 30 GiB` 时会输出 `WARNING`，建议先释放空间或挂载 `/dev/vdb`
  - `vdb.exists == true && vdb.mounted == false` 会输出 `INFO`，引导你跑 `26_plan_vdb_migration.sh`
  - JSON 落到 `/data/robot-dh/logs/storage_pressure_YYYYmmdd_HHMMSS.json`
- `27_audit_scale30_assets.sh` 审计三类 scale30 数据集，对比 local / MinIO / manifest，三者不一致会列在 `missing_local / missing_minio / wrong_size`
- `28_minio_lifecycle_plan.sh` 默认 dry-run，输出每个 bucket 的 `du`、`version info`、`ilm rule ls` 与推荐策略

## 3. MinIO 生命周期策略

默认推荐：

| Bucket | Prefix | 策略 | 应用方式 |
|--------|--------|------|----------|
| `robot-lake` | `tmp/` | 7 天过期 | `./scripts/28_minio_lifecycle_plan.sh --apply` |
| `robot-dh-artifacts` | `tmp/` | 7 天过期 | `./scripts/28_minio_lifecycle_plan.sh --apply` |
| `robot-dh-artifacts` | `runs/` | 建议 30 天过期 | 人工 `mc ilm rule add` |
| `robot-dh-artifacts` | `argo-logs/` | 建议 30 天过期 | 人工 `mc ilm rule add`，**不**进入 `28_minio_lifecycle_plan.sh --apply` 白名单（与 `tmp/` 7 天策略明显不同） |
| `robot-lake` | `ods/ dwd/ ads/` | 不自动过期 | 由 dataset_versions / lake_assets 控制 |
| `robot-lake` | `lineage/` | 建议 180 天后归档 | 人工策划 |
| `robot-datasets` | 全部 | 不自动过期 | 人工策划 |
| `robot-dh-backups` | 全部 | 保留最近 20 个或 30 天 | 人工策划，**不要**用 ILM |

`--apply` 行为：

- 仅作用于 `robot-lake/tmp/` 和 `robot-dh-artifacts/tmp/` 两条 prefix
- **不会**触碰 `argo-logs/` / `runs/` / `ods/ dwd/ ads/` / `lineage/`，这些 prefix 的过期策略由人工 `mc ilm rule add` 落
- 必须交互输入 `APPLY_LIFECYCLE` 才会真正写
- 幂等：已经存在的同等规则会跳过

`argo-logs/` 由 WSL/kind 项目部署的 `workflow-controller` 写入（v1.6 起，见 [`docs/v1_6_argo_log_archive_request.md`](v1_6_argo_log_archive_request.md) §6），人工 ILM 命令示例：

```bash
mc ilm rule add \
  --expire-days 30 \
  --prefix argo-logs/ \
  rdh/robot-dh-artifacts
mc ilm rule list rdh/robot-dh-artifacts
```

注意 versioning：

- 4 个 bucket 都已开启 versioning。`expire` 默认只删 current version，旧版本由 `NoncurrentVersionExpiration` 控制
- 要回收磁盘需要追加一条 `NoncurrentVersionExpiration N day` 规则（人工评估后再加）

## 4. PostgreSQL v1.5 schema

```bash
cd /opt/robot-dh-infra
./scripts/29_pg_apply_v1_5_schema.sh
./scripts/33_pg_apply_etl_shards_align.sh
./scripts/34_pg_apply_benchmark_align.sh
./scripts/30_pg_v1_5_smoke_test.sh
```

`29_pg_apply_v1_5_schema.sh` 行为：

- 使用 `POSTGRES_USER`（管理员）执行 `postgres/migrations/002_v1_5_scale_benchmark.sql`
- 通过 `PGOPTIONS=-c robot_dh.app_user=$ROBOT_DH_APP_USER` 把应用账号注入 migration
- migration 末尾的 `DO` 块会自动给应用账号 `GRANT SELECT/INSERT/UPDATE/DELETE` + 序列权限
- 全部 `CREATE IF NOT EXISTS`，幂等

早期 v1.5 对齐脚本：

- `33_pg_apply_etl_shards_align.sh`：执行 `postgres/migrations/003_v1_5_etl_shards_align.sql`，把 `etl_shards.shard_id` 对齐为 text，并补齐 `shard_index / duration_sec / succeeded / failed / skipped / summary_uri / error_message`
- `34_pg_apply_benchmark_align.sh`：执行 `postgres/migrations/004_v1_5_benchmark_align.sql`，补齐 `benchmark_cases` 的 `mutation / match / duration_sec / error_message` 与 `benchmark_runs` 的 `suite_path / total_cases / passed / failed / mismatched / report_uri`
- 两个脚本都使用管理员账号执行 DDL，并通过 `PGOPTIONS` 给应用账号补 GRANT；全新环境执行也应保持 no-op / 幂等

`30_pg_v1_5_smoke_test.sh` 行为：

- 用 `ROBOT_DH_APP_USER` 在 6 张新表中插入并立即删除 smoke 记录
- 通过事务保证不污染数据
- 退出码非 0 表示某张表缺失 / 权限不足

新表概览：

| 表 | 主要用途 |
|----|---------|
| `etl_perf_runs` | 单 ETL phase 的性能 / 用时 / 内存 / 状态 |
| `etl_shards` | scale ETL 的分片记录（同 plan_id + shard_id 唯一），当前主项目写入 text `shard_id` 与 `shard_index` 等聚合字段 |
| `benchmark_runs` | benchmark suite 单次执行的总览，含 case 级聚合计数与报告 URI |
| `benchmark_cases` | benchmark 单 case 的预期 / 实际 / match / 兼容 passed 字段 |
| `argo_workflow_runs` | Argo workflow 元数据 + 状态 + 完整 JSON 快照 |
| `runtime_events` | 通用事件总线（CLI / ETL / Argo / FastAPI），按 `event_id` 唯一 |

## 5. Argo Secret 准备

在云端：

```bash
cd /opt/robot-dh-infra
./scripts/31_argowf_remote_env_export.sh                # 默认 public 模式 + 脱敏
./scripts/31_argowf_remote_env_export.sh --show-secrets # 写 client/robot-dh-v1-5.env (chmod 600)
```

在 WSL host：

```bash
# 1. 先从云端 scp client/robot-dh-v1-5.env 到 WSL
set -a; source client/robot-dh-v1-5.env; set +a

# 2. 创建 namespace + ServiceAccount + RBAC（一次性）
kubectl apply -f client/k8s-argo-secret.example.yaml

# 3. 真正注入 Secret
PUBLIC_HOST=$(awk -F'[@:]' '/^ROBOT_DH_DB_URI=/{print $4}' client/robot-dh-v1-5.env) \
ROBOT_DH_APP_PASSWORD=$(awk -F'[/:]' '/^ROBOT_DH_DB_URI=/{print $5}' client/robot-dh-v1-5.env) \
MINIO_APP_SECRET_KEY=$(awk -F= '/^ROBOT_DH_S3_SECRET_KEY=/{print $2}' client/robot-dh-v1-5.env) \
REDIS_PASSWORD=$(awk -F'[/:@]' '/^ROBOT_DH_REDIS_URL=/{print $5}' client/robot-dh-v1-5.env) \
./client/k8s-create-argo-secret.example.sh
```

> 上面那段 `awk` 解析仅作示例；推荐做法是把这些字段单独导出，避免在脚本里二次解析连接串。

更多 Argo / kind 注意事项见 [`docs/v1_5_argo_env.md`](v1_5_argo_env.md)。

## 6. 验收清单

执行以下命令，全部退出码为 0 即视为 v1.5 升级通过：

```bash
cd /opt/robot-dh-infra

./scripts/06_healthcheck.sh
./scripts/25_storage_pressure_report.sh
./scripts/27_audit_scale30_assets.sh
./scripts/28_minio_lifecycle_plan.sh
./scripts/29_pg_apply_v1_5_schema.sh
./scripts/33_pg_apply_etl_shards_align.sh
./scripts/34_pg_apply_benchmark_align.sh
./scripts/30_pg_v1_5_smoke_test.sh
./scripts/31_argowf_remote_env_export.sh
```

附加要求：

- `27_audit_scale30_assets.sh` 输出的 JSON / MD 中 `missing_local / missing_minio / wrong_size` 全部为 0
- `25_storage_pressure_report.sh` 输出 `warnings` 中没有 `WARNING:` 前缀的条目
- `33_pg_apply_etl_shards_align.sh` 与 `34_pg_apply_benchmark_align.sh` 可重复执行且不破坏既有数据
- v1.4 / v1.3 已有表与 bucket 未变更
