# robot-dh-infra v1.5 存储计划

本文记录 v1.5 阶段的存储现状、风险、`/dev/vdb` 迁移草案与边界。

## 1. 当前存储现状

| 维度 | 状态 |
|------|------|
| 数据根目录 | `/data/robot-dh` |
| 所在分区 | `/dev/vda2`（root filesystem） |
| root filesystem 总容量 | 约 118 GiB（底层盘 120 GiB） |
| root filesystem 已用 | 约 63 GiB |
| `/data/robot-dh` 占用 | `datasets/` ~27 GiB + `minio/` ~27 GiB |
| 预留独立数据盘 | `/dev/vdb`，100 GiB |
| `/dev/vdb` 当前状态 | **未分区、未格式化、未挂载** |

> 体积数据来源：`./scripts/19_audit_lake_layout.sh`、`./scripts/25_storage_pressure_report.sh`，详细 JSON 落到 `/data/robot-dh/logs/`。

## 2. 风险评估

跑 30GB 级 ETL 至少会经过：

- 本地 raw 落盘（~30 GiB）
- MinIO 后端镜像（~30 GiB）
- ETL tmp / parquet 中间产物（按经验 ~30 GiB）

合计 ~90 GiB。若全部落在 root filesystem，会把可用空间压到 < 30 GiB，触发 `25_storage_pressure_report.sh` 的 `WARNING`。

短期策略：

- 不自动扩盘
- 跑大型 ETL 之前先跑 `25_storage_pressure_report.sh`
- 通过 `28_minio_lifecycle_plan.sh --apply` 让 `robot-lake/tmp/` 和 `robot-dh-artifacts/tmp/` 在 7 天后自动回收

中期策略：

- 把 `/data/robot-dh` 迁到 `/dev/vdb`（人工执行）

## 3. /dev/vdb 迁移计划（plan-only）

**v1.5 阶段不自动操作 `/dev/vdb`。**

所有 `mkfs / parted / fdisk / mount / fstab` 改动都必须人工执行。本仓库只提供计划生成器：

```bash
cd /opt/robot-dh-infra
./scripts/26_plan_vdb_migration.sh
# 或者自定义挂载点
./scripts/26_plan_vdb_migration.sh --mount-target /data2/robot-dh
```

脚本会：

1. 打印当前 `/data/robot-dh` 占用
2. 探测 `/dev/vdb` 当前状态（是否存在、是否挂载、是否已有文件系统）
3. 输出推荐挂载点、停机服务清单、rsync 计划、回滚计划
4. 把人工命令草案落到 `/data/robot-dh/logs/vdb_migration_plan_*.txt`

脚本**永远不会**：

- 执行 `mkfs / parted / fdisk / wipefs`
- 执行 `mount / umount`
- 修改 `/etc/fstab`
- 改任何数据

## 4. 人工迁移触发条件

满足以下任一条件时，再启动人工迁移流程：

- `25_storage_pressure_report.sh` 连续多次 WARNING（root avail < 30 GiB）
- 计划在 60 天内跑 100 GiB+ ETL，且 `28_minio_lifecycle_plan.sh` 释放不出来
- 业务方明确批准停机窗口

迁移流程参考 `./scripts/26_plan_vdb_migration.sh` 输出的命令草案，关键步骤：

1. 备份 PostgreSQL（`07_backup_postgres.sh`）+ MinIO（`08_backup_minio.sh`），并做恢复演练
2. 停 docker-compose（`05_down.sh`）
3. 人工执行 `mkfs.ext4 /dev/vdb` + 创建挂载点
4. `rsync -aAXHv --delete /data/robot-dh/ /data2/robot-dh/`（先 `--dry-run`）
5. 切换符号链接：`/data/robot-dh -> /data2/robot-dh`
6. 人工写 `/etc/fstab`（用 UUID）
7. `04_up.sh` + `06_healthcheck.sh` + `19_audit_lake_layout.sh`
8. 观察 24 小时后再删除 `/data/robot-dh.legacy.*`

## 5. 边界与禁止行为

| 行为 | 是否允许（v1.5 阶段） |
|------|------------------------|
| 跑 `25_storage_pressure_report.sh` | 允许（只读） |
| 跑 `26_plan_vdb_migration.sh` | 允许（只读，仅生成计划） |
| `mkfs.* /dev/vdb` | **禁止脚本自动执行**，必须人工 |
| `mount /dev/vdb ...` | **禁止脚本自动执行**，必须人工 |
| 修改 `/etc/fstab` | **禁止脚本自动执行**，必须人工 |
| `28_minio_lifecycle_plan.sh --apply` | 允许（限定到 tmp prefix 且需交互确认） |
| 删除 `/data/robot-dh/*` | 任何脚本都禁止 |
| 整 bucket 删除 | 任何脚本都禁止 |
