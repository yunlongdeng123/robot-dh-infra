# robot-dh-infra

## 目录

- [1. 项目目的](#1-项目目的)
- [2. 当前部署结论](#2-当前部署结论)
- [3. 磁盘与安全边界](#3-磁盘与安全边界)
- [4. 目录结构](#4-目录结构)
- [5. 初始化与启动流程](#5-初始化与启动流程)
- [6. Compose 行为说明](#6-compose-行为说明)
- [7. 组件说明](#7-组件说明)
- [8. WSL 接入方式总览](#8-wsl-接入方式总览)
- [9. WSL 接入清单](#9-wsl-接入清单)
- [10. kind / K8s 接入清单](#10-kind--k8s-接入清单)
- [10.5 v1.4 数据湖基础设施](#105-v14-数据湖基础设施)
- [10.6 当前数据资产 manifest](#106-当前数据资产-manifest)
- [10.7 v1.5 scale / benchmark / Argo 基础设施](#107-v15-scale--benchmark--argo-基础设施)
- [11. 备份与恢复](#11-备份与恢复)
- [12. 常用运维命令](#12-常用运维命令)
- [13. 验收与验证命令](#13-验收与验证命令)
- [14. systemd 开机自启](#14-systemd-开机自启)
- [15. 常见故障与处理](#15-常见故障与处理)
- [16. 当前建议](#16-当前建议)

## 1. 项目目的

`robot-dh-infra` 是 `robot-data-harness` 的远端基础设施项目，用于把当前本地 Win11 / WSL / kind 环境中的持久化状态与对象存储能力迁移到云服务器。

本项目负责提供三类核心组件：

- PostgreSQL：保存 dataset registry、run history、gate results、metrics 等元数据
- MinIO：保存 datasets、reports、plots、artifacts 等对象文件
- Redis：为后续异步任务队列、Streams、event bus 预留基础设施

整体职责划分如下：

- 本地 Win11 / WSL / kind：运行 `robot-dh CLI`、FastAPI、K8s Job / CronJob、validator pipeline
- 云端服务器：运行 PostgreSQL、MinIO、Redis、备份脚本、健康检查、客户端连接模板

## 2. 当前部署结论

当前代码版本：`v1.5`。本版本在 v1.4 数据湖基础上补齐 scale / benchmark / Argo 远程接入所需的运维脚本、PostgreSQL 元数据表，以及早期 v1.5 schema 的幂等对齐迁移。

当前服务器的已知结论如下：

- 当前没有独立挂载的数据盘
- 当前数据目录使用 `/data/robot-dh`
- `/data/robot-dh` 目前位于 root filesystem 上
- root filesystem 对应 `/dev/vda2`
- 严禁对 `/dev/vda2` 做分区、格式化或重建文件系统

当前项目路径说明：

- 实际项目目录：`/home/ubuntu/robot-dh-infra`
- 兼容访问路径：`/opt/robot-dh-infra -> /home/ubuntu/robot-dh-infra`

之所以保留 `/opt/robot-dh-infra`，是为了兼容你最初定义的验收命令和运维路径；当前所有脚本都可以直接从 `/opt/robot-dh-infra` 执行。

## 3. 磁盘与安全边界

### 当前策略

当前阶段直接使用 root filesystem 下的 `/data/robot-dh` 存放数据，不自动做任何磁盘破坏性操作。

### 明确禁止的自动行为

以下操作必须先检测磁盘状态、打印计划、等待人工确认后才允许执行：

- `mkfs`
- `fdisk`
- `parted`
- 新磁盘格式化
- 新磁盘挂载
- 任何会覆盖现有文件系统的数据迁移操作

### 当前脚本行为

`scripts/00_preflight.sh` 和 `scripts/01_prepare_dirs.sh` 会输出：

- `lsblk`
- `df -h`
- `findmnt`

并在 `/data` 位于 root filesystem 时明确打印：

```text
WARNING: No dedicated data disk detected; using root filesystem for /data/robot-dh.
```

如果检测到额外未挂载磁盘，脚本只会打印建议，不会自动分区、格式化或挂载。

## 4. 目录结构

项目目录：

```text
/opt/robot-dh-infra -> /home/ubuntu/robot-dh-infra
```

核心文件：

- `README.md`
- `docker-compose.yml`
- `.env.example`
- `environment.yml`
- `.gitignore`

运维脚本：

- `scripts/00_preflight.sh`
- `scripts/01_prepare_dirs.sh`
- `scripts/02_install_docker.sh`
- `scripts/03_generate_env.sh`
- `scripts/04_up.sh`
- `scripts/05_down.sh`
- `scripts/06_healthcheck.sh`
- `scripts/07_backup_postgres.sh`
- `scripts/08_backup_minio.sh`
- `scripts/09_restore_postgres.sh`
- `scripts/10_print_client_env.sh`
- `scripts/11_print_ssh_tunnel.sh`
- `scripts/12_firewall_plan.sh`
- `scripts/13_install_dataset_tools.sh`
- `scripts/14_pull_curated_datasets.sh`
- `scripts/15_audit_raw_datasets.sh`
- `scripts/16_setup_conda_env.sh`
- `scripts/17_quality_curated_samples.sh`
- `scripts/18_setup_lake_buckets.sh`
- `scripts/19_audit_lake_layout.sh`
- `scripts/20_list_remote_assets.sh`
- `scripts/21_pg_apply_lake_schema.sh`
- `scripts/22_pg_lake_smoke_test.sh`
- `scripts/23_minio_lake_smoke_test.sh`
- `scripts/24_export_lake_client_env.sh`
- `scripts/25_storage_pressure_report.sh`
- `scripts/26_plan_vdb_migration.sh`
- `scripts/27_audit_scale30_assets.sh`
- `scripts/28_minio_lifecycle_plan.sh`
- `scripts/29_pg_apply_v1_5_schema.sh`
- `scripts/30_pg_v1_5_smoke_test.sh`
- `scripts/31_argowf_remote_env_export.sh`
- `scripts/32_pull_scale_30gb_hf.sh`
- `scripts/33_pg_apply_etl_shards_align.sh`
- `scripts/34_pg_apply_benchmark_align.sh`

文档索引：

- `docs/lake_layout.md`
- `docs/v1_4_infra_runbook.md`
- `docs/v1_5_scale_runbook.md`
- `docs/v1_5_storage_plan.md`
- `docs/v1_5_argo_env.md`
- `docs/v1_5_etl_shards_align_handoff.md`
- `docs/v1_5_benchmark_align_handoff.md`

数据目录：

```text
/data/robot-dh/
	postgres/
		data/
		backups/
	minio/
		data/
		backups/
	redis/
		data/
	logs/
	tmp/
```

## 5. 初始化与启动流程

这是推荐的初始化顺序，也是当前已经验证过的主流程。

```bash
cd /opt/robot-dh-infra
./scripts/00_preflight.sh
./scripts/01_prepare_dirs.sh
./scripts/02_install_docker.sh
./scripts/03_generate_env.sh
docker compose config
./scripts/04_up.sh
./scripts/06_healthcheck.sh
```

说明：

- 如果 Docker 尚未安装，先执行 `./scripts/02_install_docker.sh`
- `.env` 已存在时，`./scripts/03_generate_env.sh` 默认不会覆盖；如需重建，使用 `--force`
- 所有服务默认仅监听 `127.0.0.1`
- 当前服务器已经为 Docker 配置了镜像加速，以降低 Docker Hub 访问超时风险

### Python / Conda 环境

当前仓库的 Python 依赖已经收敛到仓库根目录下的 `environment.yml`，不再需要继续往系统 Python 或 `~/.local` 里堆包。

推荐初始化方式：

```bash
cd /opt/robot-dh-infra
./scripts/16_setup_conda_env.sh
source ~/miniconda3/etc/profile.d/conda.sh
conda activate robot-dh
python --version
python -m pip --version
```

说明：

- `./scripts/16_setup_conda_env.sh` 会在 `~/miniconda3` 安装 Miniconda，并按 `environment.yml` 创建或更新 `robot-dh` 环境
- 如果你确实想把仓库依赖直接装进 conda 的 `base`，可以执行 `./scripts/16_setup_conda_env.sh --use-base`
- 已激活 conda 环境时，`./scripts/13_install_dataset_tools.sh` 会优先把 Python 包装进当前 conda 环境，而不是继续写入系统 Python

### 样本数据质检

当前仓库提供了面向三套样本数据的质检入口，会直接产出 schema、profile 和 calibration completeness 报告。

```bash
cd /opt/robot-dh-infra
./scripts/17_quality_curated_samples.sh
```

输出位置：

- `/data/robot-dh/datasets/manifests/quality/curated_samples_quality_report.json`
- `/data/robot-dh/datasets/manifests/quality/curated_samples_quality_report.md`

补充说明：

- 脚本默认扫描 `droid`、`bridgedata-v2`、`robomimic` 三套样本
- 仅跑单套样本时，可执行 `./scripts/17_quality_curated_samples.sh --only droid`
- 如果机器上已安装 `~/miniconda3` 且存在 `robot-dh` 环境，脚本会优先用该环境执行 Python 解析

## 6. Compose 行为说明

Compose 项目名：

```text
robot_dh_infra
```

默认绑定地址：

```text
BIND_ADDR=127.0.0.1
```

默认对外监听端口：

- PostgreSQL：`127.0.0.1:5432`
- MinIO S3 API：`127.0.0.1:9000`
- MinIO Console：`127.0.0.1:9001`
- Redis：`127.0.0.1:6379`

如果后续必须让远端主机、Pod 或外部客户端直连云服务器，请手动把 `.env` 中的 `BIND_ADDR` 改为：

```text
BIND_ADDR=0.0.0.0
```

但必须同时满足以下条件：

- 配置云安全组白名单
- 在 `.env` 中设置 `TRUSTED_CIDR`
- 在 `.env` 中设置 `SSH_TRUSTED_CIDR`
- 如需 PostgreSQL 应用账号公网直连，在 `.env` 中设置 `POSTGRES_APP_TRUSTED_CIDRS`；留空时默认回退到 `TRUSTED_CIDR`
- 执行 `./scripts/04_up.sh`，让受控 `pg_hba` 规则同步进 PostgreSQL
- 显式执行 `./scripts/12_firewall_plan.sh --apply`
- 使用强密码
- 不允许将 5432、6379、9000、9001 直接暴露给公网任意来源

## 7. 组件说明

### PostgreSQL

- 镜像：`postgres:16-alpine`，可通过 `.env` 调整
- 数据目录：`/data/robot-dh/postgres/data`
- 初始化脚本目录：`postgres/init/`
- 配置文件：`postgres/conf/postgresql.conf`

`postgres/init/01_init_robot_dh.sh` 负责：

- 确保 `robot_dh` 数据库存在
- 创建应用账号 `robot_dh_app`
- 授予数据库与 `public` schema 权限
- 启用 `pgcrypto`

注意：

- Docker 官方 Postgres entrypoint 只会在 `PGDATA` 为空时执行 `docker-entrypoint-initdb.d`
- 如果 `PGDATA` 已存在，entrypoint 不会再次自动执行初始化脚本
- 为了让已有卷也能补齐数据库与账号，`./scripts/04_up.sh` 会在容器启动后检测 `robot_dh` 是否存在；若不存在，会在容器内主动执行 `01_init_robot_dh.sh`
- `postgres/init/02_sync_pg_hba.sh` 会维护一段受控 `pg_hba.conf` 区块，把 `POSTGRES_APP_TRUSTED_CIDRS` 或 `TRUSTED_CIDR` 同步成 `robot_dh / robot_dh_app` 的放行规则
- 因此，只要更新 `.env` 中的 CIDR 并重新执行 `./scripts/04_up.sh`，容器重建后 PostgreSQL 白名单也会自动恢复，不再依赖手工 `docker exec`

### MinIO

- 数据目录：`/data/robot-dh/minio/data`
- 初始化脚本：`minio/init/init_minio.sh`
- Policy 文件：`minio/policies/robot_dh_readwrite.json`

MinIO 初始化逻辑包括：

- 创建 bucket：`robot-datasets`
- 创建 bucket：`robot-dh-artifacts`
- 创建 bucket：`robot-dh-backups`
- 创建 bucket：`robot-lake`（v1.4 数据湖统一 bucket）
- 尝试开启 versioning
- 尝试创建应用 access key / secret
- 尝试应用 `robot-dh-readwrite` policy（v1.3 已有 bucket）
- 尝试应用 `robot-dh-lake-readwrite` policy（v1.4 lake bucket）

如果某些 `mc` 子命令在当前 MinIO 版本上不可用，脚本会打印 warning，但不会让整个 Compose 栈崩溃。

### Redis

- 数据目录：`/data/robot-dh/redis/data`
- 配置文件：`redis/redis.conf`

当前 Redis 采用：

- `appendonly yes`
- `appendfsync everysec`
- `maxmemory-policy noeviction`

这符合后续 Streams / 任务队列场景，避免因为 eviction 造成静默丢任务。

## 8. WSL 接入方式总览

WSL 接入有两种模式：

### 模式 A：SSH tunnel，适用于本地 CLI / FastAPI 调试

这是默认推荐方案，优点是：

- 服务仍然只绑定在云服务器 `127.0.0.1`
- 不需要把数据库、Redis、MinIO 暴露到公网
- 对本地 WSL 调试最安全

适合：

- `robot-dh CLI`
- 本地 FastAPI 调试
- 本地人工触发任务
- 本地脚本验证 registry / artifact / report 流程

### 模式 B：公网直连或白名单直连，适用于 kind / K8s Pod

适合：

- kind 内部 Pod 直接访问远端 PostgreSQL / MinIO / Redis
- K8s Job / CronJob 直接访问云端基础设施

注意：

- kind Pod 不能使用 WSL 本机的 `127.0.0.1` SSH tunnel
- 如果 Pod 需要访问云端服务，必须使用云服务器公网 IP 或 DNS
- 必须配合安全组 / UFW 白名单

## 9. WSL 接入清单

一份独立的清单也放在 `client/wsl-access-checklist.md`。

下面是推荐执行顺序。

### 第 0 步：确认前提条件

在 WSL 本地，至少确认以下能力：

- 可以通过 `ssh ubuntu@<server>` 连到这台云服务器
- 本地 15432、19000、19001、16379 端口未被占用
- 本地有 shell 环境可导出环境变量
- 可选工具：`psql`、`redis-cli`、`curl`

可用下面命令检查本地端口：

```bash
ss -ltn '( sport = :15432 or sport = :19000 or sport = :19001 or sport = :16379 )'
```

### 第 1 步：确认远端基础设施健康

在云服务器执行：

```bash
cd /opt/robot-dh-infra
./scripts/06_healthcheck.sh
```

只有健康检查通过后，再进行 WSL 连接。

### 第 2 步：打印 SSH tunnel 命令

在云服务器执行：

```bash
cd /opt/robot-dh-infra
./scripts/11_print_ssh_tunnel.sh
```

默认会输出类似以下命令：

```bash
ssh -N \
	-L 15432:127.0.0.1:5432 \
	-L 19000:127.0.0.1:9000 \
	-L 19001:127.0.0.1:9001 \
	-L 16379:127.0.0.1:6379 \
	ubuntu@robot-dh-tencent
```

同时会检查 `client/wsl-open-tunnels.sh`：

- 如果文件不存在，会自动生成模板
- 如果文件已存在且内容不同，会保留已有版本
- 如需覆盖模板，可执行：`./scripts/11_print_ssh_tunnel.sh --force`

当前 tunnel 模板还支持以下可选变量：

- `SSH_PORT`
- `SSH_IDENTITY_FILE`

并默认启用：

- `ExitOnForwardFailure=yes`
- `ServerAliveInterval=30`
- `ServerAliveCountMax=3`

### 第 3 步：在 WSL 打开 tunnel

如果你在 WSL 本地也有这份 infra 仓库，可以直接使用客户端脚本：

```bash
SSH_HOST=robot-dh-tencent \
SSH_USER=ubuntu \
./client/wsl-open-tunnels.sh
```

如果 WSL 本地没有这份仓库，直接使用第 2 步打印出的 `ssh -N -L ...` 命令即可。

保持这个 SSH 进程常驻，不要关闭。

### 第 4 步：准备 WSL 侧环境变量

有三种方式。

#### 方式 A：先用示例模板占位

适合先接线，再替换真实密码：

```bash
source ./client/wsl-export-env.example.sh
```

或参考：

- `client/wsl-export-env.example.sh`
- `client/robot-dh-remote.env.example`

#### 方式 B：在服务器生成真实客户端环境

在云服务器执行：

```bash
cd /opt/robot-dh-infra
./scripts/10_print_client_env.sh --show-secrets
```

该命令会生成：

- `client/robot-dh-remote.env`
- `client/wsl-export-env.sh`

内容包含：

- `ROBOT_DH_DB_URI`
- `ROBOT_DH_S3_ENDPOINT_URL`
- `ROBOT_DH_S3_ACCESS_KEY`
- `ROBOT_DH_S3_SECRET_KEY`
- `ROBOT_DH_S3_DATA_BUCKET`
- `ROBOT_DH_S3_ARTIFACT_BUCKET`
- `ROBOT_DH_REDIS_URL`

#### 方式 C：仅打印脱敏版模板

```bash
cd /opt/robot-dh-infra
./scripts/10_print_client_env.sh
```

默认输出为脱敏版，适合对照变量名，不会直接把密码打印到终端。

### 第 5 步：在 WSL 导入环境变量

在 WSL 中导入后，建议执行：

```bash
set -a
source ./robot-dh-remote.env
set +a
```

如果你更习惯直接 `source` 一个带 `export` 的 shell 文件，可以使用：

```bash
source ./wsl-export-env.sh
```

如果你不使用 `.env` 文件，也可以直接 `export` 同名变量。

### 第 6 步：在 WSL 验证 tunnel 是否工作

#### 验证 PostgreSQL

```bash
psql "$ROBOT_DH_DB_URI" -c 'select current_database(), current_user;'
```

#### 验证 Redis

```bash
redis-cli -u "$ROBOT_DH_REDIS_URL" ping
```

#### 验证 MinIO API

```bash
curl -fsS "$ROBOT_DH_S3_ENDPOINT_URL/minio/health/live"
```

#### 可选：验证 MinIO Console

在浏览器访问：

```text
http://127.0.0.1:19001
```

### 第 6.5 步：使用 WSL doctor 做一次整体检查

如果你已经把 `client/` 目录拷到 WSL，可以在 WSL 中执行：

```bash
source ./wsl-export-env.sh
./wsl-remote-doctor.sh
```

这个脚本会检查：

- tunnel 端口是否在本地监听
- 必要环境变量是否已导入
- `psql`、`redis-cli`、`curl`、`ssh` 是否存在
- PostgreSQL / Redis / MinIO 是否可连通

### 第 7 步：接入 robot-data-harness

在 WSL 中运行 `robot-data-harness` CLI、FastAPI 或本地脚本前，确保这些环境变量已经导入到当前 shell：

- `ROBOT_DH_DB_URI`
- `ROBOT_DH_S3_ENDPOINT_URL`
- `ROBOT_DH_S3_ACCESS_KEY`
- `ROBOT_DH_S3_SECRET_KEY`
- `ROBOT_DH_S3_DATA_BUCKET`
- `ROBOT_DH_S3_ARTIFACT_BUCKET`
- `ROBOT_DH_REDIS_URL`

如果你的主项目使用 `.env`、K8s Secret 或 Helm values，只需要把这些变量名映射过去即可。

### 第 8 步：确认你的场景是否真的适合 tunnel

以下场景适合 tunnel：

- 本地 CLI
- 本地 FastAPI
- 本地调试脚本
- 本地一次性回放或人工验证

以下场景不适合 tunnel：

- kind 内 Pod
- 远端宿主机上的其他服务
- 需要长期稳定提供给非本机用户的访问链路

如果是这些场景，请改用“公网白名单直连模式”。

## 10. kind / K8s 接入清单

如果 kind 内的 Pod 需要访问云端 PostgreSQL、MinIO、Redis，请使用以下策略：

### 步骤 1：开放监听地址

编辑 `.env`：

```text
BIND_ADDR=0.0.0.0
TRUSTED_CIDR=<your_trusted_cidr>
SSH_TRUSTED_CIDR=<your_admin_ssh_cidr>
POSTGRES_APP_TRUSTED_CIDRS=<your_trusted_cidr>
```

然后重启栈：

```bash
cd /opt/robot-dh-infra
./scripts/04_up.sh
```

这里的 `./scripts/04_up.sh` 不只是重启容器，还会把 `POSTGRES_APP_TRUSTED_CIDRS` 同步到 PostgreSQL 的受控 `pg_hba` 区块。

### 步骤 2：配置安全组 / UFW 白名单

仅允许可信来源访问：

- 5432
- 6379
- 9000
- 9001

可以先查看计划：

```bash
cd /opt/robot-dh-infra
./scripts/12_firewall_plan.sh
```

如果确定要应用：

```bash
cd /opt/robot-dh-infra
./scripts/12_firewall_plan.sh --apply
```

`./scripts/12_firewall_plan.sh` 会默认读取 `.env` 中的 `TRUSTED_CIDR` 与 `SSH_TRUSTED_CIDR`。只有在你临时想覆盖 `.env` 的情况下，才需要额外传参或临时导出环境变量。

### 步骤 3：在 K8s 中使用公网 IP / DNS

不要使用：

- `127.0.0.1:15432`
- `127.0.0.1:19000`
- `127.0.0.1:16379`

要使用：

- `PUBLIC_SERVER_IP_OR_DNS:5432`
- `PUBLIC_SERVER_IP_OR_DNS:9000`
- `PUBLIC_SERVER_IP_OR_DNS:6379`

### 步骤 4：创建 Secret

可参考：

- `client/k8s-secret.example.yaml`
- `client/k8s-create-remote-secret.example.sh`

## 10.5 v1.4 数据湖基础设施

v1.4 在 v1.3 基础上叠加一层数据湖 / ETL 元数据基础设施，本仓库只负责 bucket、prefix、PostgreSQL schema、审计脚本和客户端模板，不实现 Python 业务 ETL。

详细说明：

- `docs/lake_layout.md`：分层模型、bucket / prefix 规范、`_manifest.json` 建议字段、PostgreSQL 元数据表
- `docs/v1_4_infra_runbook.md`：初始化顺序、健康检查、资产发现、客户端 env 导出、K8s Secret 注入、回滚、常见故障

### 10.5.1 数据湖分层

数据湖统一落在 `robot-lake` bucket，按 `raw / ods / dwd / ads / lineage / tmp` 六类 prefix 组织：

```text
robot-lake/
  raw/{dataset_id}/{version}/
  ods/{dataset_id}/{version}/
  dwd/{dataset_id}/{version}/
  ads/quality/
  lineage/events/yyyy/mm/dd/
  tmp/{run_id}/
```

各层职责：

- `raw`：原始机器人数据资产（`endpose.pt`、`video.mp4`、`meta.yaml`、`_manifest.json`），只追加
- `ods`：标准化明细 parquet（`pose.parquet`、`video_meta.parquet`、`episode_meta.parquet`）
- `dwd`：清洗 + 特征层（`pose_feature.parquet`、`press_event.parquet`、`trajectory_segment.parquet`、`episode_feature.parquet`）
- `ads`：应用指标（`dataset_quality_summary.parquet`、`validator_failure_stats.parquet`、`episode_quality_score.parquet`）
- `lineage`：按日分区的 JSONL 血缘事件
- `tmp`：ETL 作业临时区，按 `run_id` 隔离

`robot-datasets` 继续作为 v1.3 原始数据集集中地，不会被替换或迁移。

### 10.5.2 PostgreSQL 元数据 schema

`postgres/migrations/001_lake_metadata.sql` 增量创建 5 张表（不破坏 v1.3 业务表）：

- `lake_assets`：单对象元数据（uri / size / row_count / checksum）
- `etl_jobs`：ETL 作业运行记录（job_type / status / metrics_json）
- `lineage_edges`：source_uri → target_uri 血缘边
- `dataset_versions`：dataset 版本聚合（raw / ods / dwd uri 一行）
- `quality_snapshots`：quality gate 结果快照

所有表均使用 `CREATE TABLE IF NOT EXISTS`，迁移脚本可重复执行。

### 10.5.3 v1.4 执行顺序

```bash
cd /opt/robot-dh-infra

./scripts/06_healthcheck.sh
./scripts/18_setup_lake_buckets.sh
./scripts/21_pg_apply_lake_schema.sh
./scripts/22_pg_lake_smoke_test.sh
./scripts/23_minio_lake_smoke_test.sh
./scripts/19_audit_lake_layout.sh
./scripts/20_list_remote_assets.sh
./scripts/24_export_lake_client_env.sh
```

说明：

- `18_setup_lake_buckets.sh`：创建 `robot-lake` bucket、开启 versioning、写 `.keep` 占位、应用 `robot-dh-lake-readwrite` policy，可重复执行
- `21_pg_apply_lake_schema.sh`：以管理员账号应用 v1.4 迁移，幂等
- `22_pg_lake_smoke_test.sh`：用 `robot_dh_app` 在 5 张表上插入并立即删除一组 smoke 记录，验证应用账号权限
- `23_minio_lake_smoke_test.sh`：用 `MINIO_APP_ACCESS_KEY` 往 `robot-lake/tmp/smoke_*/` 写入再删除一个小对象，验证 lake policy
- `19_audit_lake_layout.sh`：检查 6 个 prefix 占位、bucket versioning、5 张元数据表、`/data/robot-dh` 磁盘
- `20_list_remote_assets.sh`：扫描 `robot-datasets/raw/` 和 `robot-lake/raw/`，输出候选 dataset + endpose/video/meta 检查；JSON 落到 `/data/robot-dh/logs/remote_assets_YYYYmmdd_HHMMSS.json`
- `24_export_lake_client_env.sh`：默认输出脱敏 env；`--show-secrets` 才写 `client/robot-dh-lake.env`（权限 `0600`）

### 10.5.4 客户端 env / K8s Secret

v1.4 单独提供面向数据湖的客户端模板，与 v1.3 模板并存：

- `client/robot-dh-lake.env.example`：包含 `ROBOT_DH_ARTIFACT_STORE` 和 `ROBOT_DH_S3_LAKE_BUCKET`，适合主项目 `robot-data-harness` 直接 `set -a; source` 使用
- `client/k8s-lake-secret.example.yaml`：K8s Secret 模板，namespace `robot-dh`，Secret 名 `robot-dh-lake-secrets`
- `client/k8s-create-lake-secret.example.sh`：示例脚本，通过环境变量注入真实密码并用 `kubectl apply` 创建 / 更新 Secret

WSL 接入流程不变，只需要把 `source ./client/robot-dh-remote.env` 替换成 `source ./client/robot-dh-lake.env` 即可获得 lake 相关变量。

## 10.6 当前数据资产 manifest

本章节给出当前服务器上**已存在**的数据资产清单，便于运维、回放和审计。结构规范见 `docs/lake_layout.md`，本节只反映"当下这台机器上实际有什么"。

> 截至 `2026-05-23`：服务器已保留早期样本数据，并新增一批 `scale30` raw 数据。`scale30` 已完成本地文件大小校验，并已镜像到 MinIO `robot-datasets` bucket。

### 10.6.1 物理存储概览

| 维度 | 当前状态 |
|------|----------|
| 数据根目录 | `/data/robot-dh/` |
| 所在分区 | `/dev/vda2`（root filesystem） |
| 分区容量 | 118 GiB 可用视图（底层盘 120 GiB） |
| root filesystem 已用容量 | ~63 GiB |
| `/data/robot-dh` 主要占用 | `datasets/` ~27 GiB；`minio/` ~27 GiB |
| 数据资产合计 | 本地 raw + MinIO 后端约 54 GiB（包含同一批 raw 数据的两份落点） |
| 预留数据盘 | `/dev/vdb`（100 GiB，**未挂载**） |

注意：

- `/dev/vdb` 是当前预留的独立数据盘，尚未分区 / 格式化 / 挂载，禁止自动操作（见 [3. 磁盘与安全边界](#3-磁盘与安全边界)）。
- 后续数据量上来后再单独规划 `/dev/vdb` 的迁移方案，目前 MinIO 后端、PostgreSQL data、备份目录都落在 root filesystem。

### 10.6.2 本地目录数据

`/data/robot-dh/` 各子目录当前占用：

| 子目录 | 占用 | 内容 |
|--------|------|------|
| `datasets/raw/` | ~27 GiB | 原始数据集本地缓存（与 MinIO `robot-datasets/raw/` 同步） |
| `datasets/manifests/` | ~2.6 MiB | 数据集来源 / 校验 / 索引清单，包含 quality 报告与 scale30 manifest |
| `minio/data/` | ~27 GiB | MinIO 后端存储（承载 4 个 bucket，含 `robot-datasets` raw 镜像） |
| `postgres/data/` | 152 KiB | PostgreSQL data 目录 |
| `redis/data/` | 16 KiB | Redis AOF 数据 |
| `cache/` / `logs/` / `tmp/` | < 1 MiB | 缓存、日志、临时目录 |

`datasets/raw/` 内的样本数据集来源（与 `manifests/*_source.json` 对应）：

| Dataset | 本地路径 | 大小 | 来源 repo | revision | 下载工具 |
|---------|----------|------|-----------|----------|----------|
| `droid/lerobot_sample` | `raw/droid/lerobot_sample/` | 1.6 GiB | HF `lerobot/droid_1.0.1` | `bd92a2c4` | `huggingface_hub.snapshot_download` |
| `droid/calibration` | `raw/droid/calibration/` | 32 KiB | HF `KarlP/droid` | `cbbf1ac2` | `huggingface_hub.snapshot_download` |
| `bridgedata_v2/sample` | `raw/bridgedata_v2/sample/` | 228 MiB | HF `mbodiai/oxe_bridge_v2`（`data/shard_0-*.parquet`） | n/a | `huggingface_hub.hf_hub_download` |
| `robomimic/sample` | `raw/robomimic/sample/` | 45 MiB | HF `robomimic/robomimic_datasets` | `74fa0184` | `huggingface_hub.snapshot_download` |

所有下载都走 `https://hf-mirror.com`（HuggingFace 国内镜像），原始路径与上游一致，可直接对账。

`datasets/raw/scale30/` 内的新增 scale30 数据：

| Dataset | 本地路径 | 文件数 | manifest 校验 | 本地占用 | 说明 |
|---------|----------|--------|----------------|----------|------|
| `bridgedata_v2_scale30` | `raw/scale30/bridgedata_v2_scale30/v1/` | 2 | 2/2 存在，大小匹配 | 228 MiB | BridgeData V2 parquet shard + README |
| `droid_lerobot_scale30` | `raw/scale30/droid_lerobot_scale30/v1/` | 181 | 181/181 存在，大小匹配 | 18 GiB | LeRobot parquet / mp4 / meta 子集 |
| `robomimic_scale30` | `raw/scale30/robomimic_scale30/v1/` | 27 | 27/27 存在，大小匹配 | 6.2 GiB | Robomimic HDF5 子集 |

本次 scale30 manifest 校验结果：

```text
bridgedata_v2_scale30: files=2 present=2 missing=0 wrong_size=0 bytes_present=238439540
droid_lerobot_scale30: files=181 present=181 missing=0 wrong_size=0 bytes_present=19269486538
robomimic_scale30: files=27 present=27 missing=0 wrong_size=0 bytes_present=6557021689
TOTAL: files=210 bytes_present=26064947767 GiB=24.275 ok=True
```

### 10.6.3 MinIO bucket 数据

四个 bucket 都已开启 versioning，应用账号 `MINIO_APP_ACCESS_KEY` 通过 `robot-dh-readwrite` + `robot-dh-lake-readwrite` 两条 policy 组合访问。

| Bucket | 体积 | 对象数 | 定位 | 主要内容 |
|--------|------|--------|------|----------|
| `robot-datasets` | 26 GiB | 701 | v1.3 原始数据集集中地 | `raw/{droid, bridgedata_v2, robomimic}/...`、`raw/{bridgedata_v2_scale30, droid_lerobot_scale30, robomimic_scale30}/...` + `manifests/*` |
| `robot-dh-artifacts` | 9.9 MiB | 123 | validator / quality gate 报告产物 | `runs/{run_id}/{gate_report.json, report.html, report.json, plots/*.png}` |
| `robot-dh-backups` | 0 B | 0 | PostgreSQL / MinIO 备份归档 | 暂无；由 `scripts/07_backup_postgres.sh` / `scripts/08_backup_minio.sh` 写入 |
| `robot-lake` | 45 MiB | 33 | v1.4 数据湖统一 bucket | `raw/ ods/ dwd/ ads/ lineage/ tmp/` 六层 prefix |

#### `robot-datasets` 主要对象

| 对象 | 大小 | 格式 | 说明 |
|------|------|------|------|
| `raw/droid/lerobot_sample/videos/observation.images.exterior_2_left/chunk-000/file-000.mp4` | 494 MiB | MP4 | 外视角 2 左相机 |
| `raw/droid/lerobot_sample/videos/observation.images.exterior_1_left/chunk-000/file-000.mp4` | 493 MiB | MP4 | 外视角 1 左相机 |
| `raw/droid/lerobot_sample/videos/observation.images.wrist_left/chunk-000/file-000.mp4` | 481 MiB | MP4 | 腕部左相机 |
| `raw/droid/lerobot_sample/data/chunk-000/file-000.parquet` | 82 MiB | Parquet | LeRobot 格式 pose + 索引 |
| `raw/bridgedata_v2/sample/data/shard_0-00000-of-00001.parquet` | 227 MiB | Parquet | OXE Bridge V2 shard（含动作、状态、视频帧） |
| `raw/robomimic/sample/v1.5/can/ph/low_dim_v15.hdf5` | 45 MiB | HDF5 | Robomimic low-dim 观测 |
| `raw/droid_lerobot_scale30/v1/{data,videos,meta}/...` | 18 GiB 合计 | Parquet / MP4 / JSON | scale30 LeRobot 子集，含 data、videos、meta |
| `raw/robomimic_scale30/v1/v1.5/**/*.hdf5` | 6.1 GiB 合计 | HDF5 | scale30 Robomimic 子集 |
| `raw/bridgedata_v2_scale30/v1/data/shard_0-00000-of-00001.parquet` | 227 MiB | Parquet | scale30 BridgeData V2 shard |
| `manifests/scale30/*` | 242 KiB 合计 | JSON / TXT | scale30 下载选择清单与 SHA256 摘要 |
| `manifests/raw_dataset_summary.txt` | 3.2 KiB | TXT | 全量 raw 数据集体积汇总 |
| `manifests/{dataset}_*_source.json` | ~300 B | JSON | 上游 repo / revision / 工具 / 时间 |
| `manifests/{dataset}_*_sha256.txt` | 几 KB | TXT | 每文件 SHA256 |
| `manifests/{dataset}_*_files.tsv` | 几 KB | TSV | 逐文件路径 + 大小索引 |

`robot-datasets` 中当前主要 raw 前缀占用：

| Prefix | 体积 | 对象数 |
|--------|------|--------|
| `raw/droid_lerobot_scale30/` | 18 GiB | 546 |
| `raw/robomimic_scale30/` | 6.1 GiB | 84 |
| `raw/bridgedata_v2_scale30/` | 227 MiB | 9 |
| `raw/droid/` | 1.5 GiB | 29 |
| `raw/bridgedata_v2/` | 227 MiB | 5 |
| `raw/robomimic/` | 45 MiB | 9 |
| `manifests/scale30/` | 242 KiB | 5 |

#### `robot-dh-artifacts` 主要对象

按 `runs/{run_id}/` 组织，单个 run 约 700 KiB：

- `gate_report.json`：quality gate 结论
- `report.html` / `report.json`：可视化报告
- `plots/{euler_angles, velocity_profile, xy_clusters, z_press_events}.png`：4 张诊断图

当前已落库的 run：`api-run-v13-test`、`k8s-demo`、`local-demo-v12-test`、`public-demo-v13`、`public-demo-v13-rerun` 等共 5+ 个，全部由主项目 `robot-data-harness` 写入。

#### `robot-lake` 各层快照

`robot-lake` 当前已被 ETL 写入两套样本：`droid/lerobot_sample` 和 `robomimic/sample`。每层都附带 `_manifest.json`。

| Prefix | 体积 | 内容 |
|--------|------|------|
| `ods/droid/lerobot_sample/` | ~21 MiB | `pose.parquet`（321344 行）、`video_meta.parquet`、`episode_meta.parquet`（1074 行）+ `_manifest.json` |
| `ods/robomimic/sample/` | ~1.6 MiB | `pose.parquet`、`episode_meta.parquet` + `_manifest.json` |
| `dwd/droid/lerobot_sample/` | ~21 MiB | `pose_feature.parquet`、`press_event.parquet`（2194 个 press 事件）、`trajectory_segment.parquet`（22535 段）、`episode_feature.parquet`（1074 个 episode）+ `_manifest.json` |
| `dwd/robomimic/sample/` | ~1.9 MiB | 同上四张 parquet + `_manifest.json` |
| `ads/quality/` | ~38 KiB | `dataset_quality_summary.parquet`（2 行）、`validator_failure_stats.parquet`（7 行）、`episode_quality_score.parquet`（1274 行）+ `_manifest.json` |
| `lineage/events/2026/05/22/*.jsonl` | ~4.5 KiB | 5 条血缘事件（normalize / build_features / build_ads） |

每个 `_manifest.json` 包含的字段：

- `dataset_id`、`version`、`layer`、`created_at`、`schema_version`
- `source_uris` / `output_uri`
- `files[]`：每个对象的 `path` / `uri` / `format` / `size_bytes` / `row_count` / `checksum_sha256`
- `metrics`：ETL 输出统计（rows、duration_ms、episode 数、press 数等）
- `job`：`job_id`、`job_type`、`started_at` / `finished_at` / `duration_sec`
- `code.package_version`

> 这些 lake 数据由主项目 `robot-data-harness` 的 ETL 作业写入，本仓库只负责 bucket / prefix / schema / policy，不直接生产业务数据。

### 10.6.4 PostgreSQL 元数据

应用账号 `robot_dh_app` 持有的业务表按版本分为：

- v1.3：dataset registry、run history、gate result、metrics 等
- v1.4：`lake_assets`、`etl_jobs`、`lineage_edges`、`dataset_versions`、`quality_snapshots`（由 `postgres/migrations/001_lake_metadata.sql` 创建）
- v1.5：`etl_perf_runs`、`etl_shards`、`benchmark_runs`、`benchmark_cases`、`argo_workflow_runs`、`runtime_events`（由 `postgres/migrations/002_v1_5_scale_benchmark.sql` 创建；早期 v1.5 环境再用 003 / 004 对齐迁移补列）

当前元数据表规模仍很小，实际体积以 `du -sh /data/robot-dh/postgres/data` 为准；备份目录 `postgres/backups/` 默认由备份脚本按需生成。可通过 `./scripts/22_pg_lake_smoke_test.sh` 验证 v1.4 元数据表，通过 `./scripts/30_pg_v1_5_smoke_test.sh` 验证 v1.5 元数据表与权限。

### 10.6.5 资产发现命令

如需重新生成本节快照内容，按需执行：

```bash
cd /opt/robot-dh-infra

./scripts/15_audit_raw_datasets.sh
./scripts/19_audit_lake_layout.sh
./scripts/20_list_remote_assets.sh
```

`20_list_remote_assets.sh` 会扫描 `robot-datasets/raw/` 与 `robot-lake/raw/`，在 `/data/robot-dh/logs/remote_assets_YYYYmmdd_HHMMSS.json` 落一份机器可读的快照。

## 10.7 v1.5 scale / benchmark / Argo 基础设施

v1.5 不引入新进程，只在 v1.4 基础上扩展运维与元数据。详细 runbook 见：

- [`docs/v1_5_scale_runbook.md`](docs/v1_5_scale_runbook.md)
- [`docs/v1_5_storage_plan.md`](docs/v1_5_storage_plan.md)
- [`docs/v1_5_argo_env.md`](docs/v1_5_argo_env.md)

### 10.7.1 scale30 数据资产说明

当前服务器已有约 24.275 GiB 的 scale30 数据，分布如下（详见 [10.6 当前数据资产 manifest](#106-当前数据资产-manifest)）：

| Dataset | 本地路径 | 大小 |
|---------|----------|------|
| `bridgedata_v2_scale30` | `raw/scale30/bridgedata_v2_scale30/v1/` | 228 MiB |
| `droid_lerobot_scale30` | `raw/scale30/droid_lerobot_scale30/v1/` | 18 GiB |
| `robomimic_scale30` | `raw/scale30/robomimic_scale30/v1/` | 6.2 GiB |
| **合计** | | **24.275 GiB** |

执行 `./scripts/27_audit_scale30_assets.sh` 可重新生成审计 JSON + Markdown，落到 `/data/robot-dh/datasets/manifests/scale30/scale30_audit_YYYYmmdd_HHMMSS.{json,md}`。

> 拉取 scale30 数据的原脚本保留为 `scripts/32_pull_scale_30gb_hf.sh`（v1.5 把 25 号让给了 storage_pressure_report）。

### 10.7.2 存储风险说明

| 维度 | 状态 |
|------|------|
| root filesystem 容量 | 约 118 GiB，已用约 63 GiB |
| `/data/robot-dh` 占用 | `datasets/` ~27 GiB + `minio/` ~27 GiB |
| `/dev/vdb`（预留数据盘） | 100 GiB，**未挂载** |

跑 30GB 级 ETL 之前必须执行：

```bash
cd /opt/robot-dh-infra
./scripts/25_storage_pressure_report.sh
```

报告会打印 `lsblk / df / findmnt / du`、MinIO bucket 用量、`/dev/vdb` 状态；root filesystem 可用 < 30 GiB 时输出 `WARNING`。JSON 落到 `/data/robot-dh/logs/storage_pressure_*.json`。

`/dev/vdb` 暂不自动操作。要做迁移计划：

```bash
./scripts/26_plan_vdb_migration.sh
```

脚本仅生成迁移命令草案与回滚计划，**不**执行 `mkfs / mount / fstab` 改动。任何破坏性命令必须人工二次确认后执行。

`28_minio_lifecycle_plan.sh` 默认 dry-run，打印各 bucket 的 `du / version / ilm`，并给出推荐策略；`--apply` 仅作用于 `robot-lake/tmp/` 和 `robot-dh-artifacts/tmp/` 两条 prefix，需要交互输入 `APPLY_LIFECYCLE` 才会真正写。

### 10.7.3 v1.5 PostgreSQL schema

`postgres/migrations/002_v1_5_scale_benchmark.sql` 新增 6 张表，与 v1.3 / v1.4 已有表并存，全部 `CREATE IF NOT EXISTS`：

| 表 | 主要用途 |
|----|---------|
| `etl_perf_runs` | 单 ETL phase 的 input/output bytes、duration、peak memory 等性能数据 |
| `etl_shards` | scale ETL 的分片记录（`UNIQUE(plan_id, shard_id)`），与主项目 `robot-data-harness` 的 SQLAlchemy 模型对齐 |
| `benchmark_runs` | benchmark suite 单次执行的总览（`benchmark_id` 唯一），同步含 case 级聚合计数 |
| `benchmark_cases` | benchmark 单 case 的 expected / actual / match / passed |
| `argo_workflow_runs` | Argo Workflow 元数据 + 状态 + 完整 JSON 快照 |
| `runtime_events` | 通用事件总线（CLI / ETL / Argo / FastAPI），按 `event_id` 唯一 |

`etl_shards` 字段约定（与主项目模型一致）：

- `shard_id`：`text NOT NULL`，复合主键字符串 `'plan-<ts>-<hash>::shard-<idx>'`
- `shard_index`：0-based 分片序号，便于按序汇总 / 排错
- `duration_sec / succeeded / failed / skipped`：单分片执行统计
- `summary_uri`：分片摘要 JSON 在 `robot-lake/tmp/...` 的位置
- `error_message`：FAIL 时的错误摘要
- `shard_uri / assigned_worker`：v1.5 早期遗留字段，主项目当前不写不读，保留兼容，不要用于新逻辑

`benchmark_runs` 字段约定（与主项目模型一致）：

- `suite_path`：suite 定义 YAML 的 URI（通常落在 `robot-lake/tmp/<bench_id>/...`）
- `total_cases / passed / failed / mismatched`：case 级聚合计数
- `report_uri`：可视化报告（HTML）落在 `robot-dh-artifacts/...` 的 URI
- 旧字段 `status / duration_sec / metrics_json` 保留不变

`benchmark_cases` 字段约定（与主项目模型一致）：

- `match`：`boolean nullable`，新口径的"是否匹配预期"
  - `TRUE` = `actual_status` 与 `expected_status` 匹配，且 `expected_failed_validators` 为空或是 `actual_failed_validators` 的子集
  - `FALSE` = 不匹配或 case 运行异常
  - `NULL` = 未知 / 历史数据未回填
- `mutation`：主项目新口径的 mutation 名称
- `duration_sec`：单 case 执行耗时
- `error_message`：异常摘要
- 兼容字段：`passed`（boolean）/ `mutation_type`（text），主项目改写 `match` / `mutation`；exporter 按 `COALESCE(match, passed)` / `COALESCE(mutation, mutation_type)` 聚合，避免补列后旧数据变 unknown

应用与验收：

```bash
cd /opt/robot-dh-infra
./scripts/29_pg_apply_v1_5_schema.sh     # 幂等，复用管理员账号
./scripts/30_pg_v1_5_smoke_test.sh       # 用 robot_dh_app 在 6 张表插入 + 删除 smoke 行
```

`29_pg_apply_v1_5_schema.sh` 通过 `PGOPTIONS='-c robot_dh.app_user=$ROBOT_DH_APP_USER'` 把应用账号注入 migration，migration 末尾的 `DO` 块会自动给应用账号 `GRANT SELECT/INSERT/UPDATE/DELETE` + 序列权限，避免重复维护 GRANT 脚本。

#### 从早期 v1.5 升级（etl_shards 对齐）

如果环境是在 002 早期版本（`shard_id int NOT NULL`、缺少 `shard_index / duration_sec / succeeded / failed / skipped / summary_uri / error_message` 7 列）下建表的，需要再跑一次 003 对齐迁移：

```bash
cd /opt/robot-dh-infra
./scripts/33_pg_apply_etl_shards_align.sh
```

行为说明：

- 用管理员账号执行 `postgres/migrations/003_v1_5_etl_shards_align.sql`，绕开 `robot_dh_app` 无 DDL 权限的限制
- `shard_id` 从 `int` 转 `text`（旧表 soft-mode 下未成功写入，转换零数据风险；已是 text 则跳过）
- 按需 `ADD COLUMN IF NOT EXISTS` 补齐 7 列
- 末尾的 `DO` 块通过 `PGOPTIONS` 注入的 `robot_dh.app_user` GUC 自动给应用账号补 GRANT
- 全程幂等，可重复执行；全新环境无需跑此脚本，直接由 002 创建对齐后的表

#### 从早期 v1.5 升级（benchmark_cases / benchmark_runs 对齐）

如果环境是在 002 早期版本（`benchmark_cases` 缺 `mutation / match / duration_sec / error_message`；`benchmark_runs` 缺 `suite_path / total_cases / passed / failed / mismatched / report_uri`）下建表的，需要再跑一次 004 对齐迁移：

```bash
cd /opt/robot-dh-infra
./scripts/34_pg_apply_benchmark_align.sh
```

行为说明：

- 用管理员账号执行 `postgres/migrations/004_v1_5_benchmark_align.sql`
- 给 `benchmark_cases` 补 `mutation / match / duration_sec / error_message` 4 列
- 给 `benchmark_runs` 补 `suite_path / total_cases / passed / failed / mismatched / report_uri` 6 列
- 历史数据回填：`match <- passed`、`mutation <- mutation_type`（仅在新列 `IS NULL` 时回填，幂等）
- 旧列 `passed` / `mutation_type` **不删除**，留作 exporter `COALESCE(match, passed)` / `COALESCE(mutation, mutation_type)` 聚合，避免旧 benchmark 历史变 unknown
- 末尾的 `DO` 块通过 `PGOPTIONS` 注入的 `robot_dh.app_user` GUC 自动给应用账号补 GRANT
- 全程幂等，可重复执行；全新环境无需跑此脚本，直接由 002 创建对齐后的表

### 10.7.4 Argo 远程连接注意事项

| 接入点 | 允许的连接方式 |
|--------|----------------|
| WSL host 本身的进程（CLI / FastAPI） | SSH tunnel（`127.0.0.1:15432/19000/16379`）或公网直连 |
| kind / Argo Pod | **必须**走公网 IP/DNS（`5432 / 9000 / 6379`），不能用 WSL 上的 `127.0.0.1` |

`./client/k8s-create-argo-secret.example.sh` 默认拒绝 `127.0.0.1` / `localhost` 作为 `PUBLIC_HOST`，除非显式加 `--allow-localhost`。

`scripts/12_firewall_plan.sh` 仍是控制端口暴露范围的唯一入口；任何对外暴露 5432/9000/6379 的操作都必须先在防火墙白名单中放行。

### 10.7.5 为 WSL / kind / Argo 注入 env

云端生成 env：

```bash
cd /opt/robot-dh-infra
./scripts/31_argowf_remote_env_export.sh                # 默认 public + 脱敏
./scripts/31_argowf_remote_env_export.sh --show-secrets # 写 client/robot-dh-v1-5.env (chmod 600)
./scripts/31_argowf_remote_env_export.sh --mode tunnel  # 仅给 WSL host 本机进程使用
```

WSL 端注入 Secret：

```bash
# namespace / ServiceAccount / RBAC（一次性）
kubectl apply -f client/k8s-argo-secret.example.yaml

# 真实凭据
PUBLIC_HOST=<云端公网 IP/DNS> \
ROBOT_DH_APP_PASSWORD=*** \
MINIO_APP_SECRET_KEY=*** \
REDIS_PASSWORD=*** \
./client/k8s-create-argo-secret.example.sh
```

Workflow 引用：

```yaml
spec:
  serviceAccountName: robot-dh-argo
  templates:
    - name: normalize
      container:
        image: ghcr.io/your-org/robot-data-harness:v1.5
        envFrom:
          - secretRef:
              name: robot-dh-v1-5-secrets
```

更详细的 RBAC / 故障排查见 [`docs/v1_5_argo_env.md`](docs/v1_5_argo_env.md)。

### 10.7.6 v1.5 验收

```bash
cd /opt/robot-dh-infra

./scripts/06_healthcheck.sh
./scripts/25_storage_pressure_report.sh
./scripts/27_audit_scale30_assets.sh
./scripts/28_minio_lifecycle_plan.sh
./scripts/29_pg_apply_v1_5_schema.sh
./scripts/33_pg_apply_etl_shards_align.sh    # 老环境对齐 etl_shards；新环境跑一次也 no-op
./scripts/34_pg_apply_benchmark_align.sh     # 老环境对齐 benchmark_cases / benchmark_runs；新环境跑一次也 no-op
./scripts/30_pg_v1_5_smoke_test.sh
./scripts/31_argowf_remote_env_export.sh
```

通过条件：

- 所有脚本以 `0` 退出
- `27_audit_scale30_assets.sh` 报告中 `missing_local / missing_minio / wrong_size` 均为 0
- `25_storage_pressure_report.sh` 没有 `WARNING:` 级别条目
- `30_pg_v1_5_smoke_test.sh` 在 `robot_dh_app` 账号下 6 张表均可插入 + 删除
- `33_pg_apply_etl_shards_align.sh` 在已对齐环境上重复执行时只输出 `跳过 / no-op` 信息
- `34_pg_apply_benchmark_align.sh` 在已对齐环境上重复执行时只命中 `ADD COLUMN IF NOT EXISTS` 的 no-op 分支
- v1.3 / v1.4 已有表 / bucket / 数据无任何变更
- `client/robot-dh-v1-5.env` 仅在显式传 `--show-secrets` 时生成，且权限为 `0600`

## 11. 备份与恢复

### PostgreSQL 备份

```bash
cd /opt/robot-dh-infra
./scripts/07_backup_postgres.sh
```

输出目录：

```text
/data/robot-dh/postgres/backups/robot_dh_YYYYmmdd_HHMMSS.dump
```

保留策略：

- 优先保留最近 20 个备份
- 对超过 7 天且不在最近 20 个中的备份进行清理

### MinIO 备份

```bash
cd /opt/robot-dh-infra
./scripts/08_backup_minio.sh
```

输出目录：

```text
/data/robot-dh/minio/backups/YYYYmmdd_HHMMSS/
```

### PostgreSQL 恢复

```bash
cd /opt/robot-dh-infra
./scripts/09_restore_postgres.sh /path/to/backup.dump
```

如需显式重建目标数据库：

```bash
./scripts/09_restore_postgres.sh /path/to/backup.dump --drop-db
```

恢复脚本会要求输入确认字符串：

- `RESTORE`
- 在 `--drop-db` 模式下还需要额外确认数据库重建

## 12. 常用运维命令

启动：

```bash
cd /opt/robot-dh-infra
./scripts/04_up.sh
```

停止：

```bash
./scripts/05_down.sh
```

健康检查：

```bash
./scripts/06_healthcheck.sh
```

查看 SSH tunnel 命令：

```bash
./scripts/11_print_ssh_tunnel.sh
```

输出脱敏版客户端变量：

```bash
./scripts/10_print_client_env.sh
```

## 13. 验收与验证命令

以下命令应可手动执行成功。

### 主流程验收

```bash
cd /opt/robot-dh-infra
./scripts/00_preflight.sh
./scripts/01_prepare_dirs.sh
./scripts/03_generate_env.sh
docker compose config
./scripts/04_up.sh
./scripts/06_healthcheck.sh
./scripts/11_print_ssh_tunnel.sh
```

### v1.4 数据湖基础设施验收

```bash
cd /opt/robot-dh-infra

./scripts/06_healthcheck.sh
./scripts/18_setup_lake_buckets.sh
./scripts/21_pg_apply_lake_schema.sh
./scripts/22_pg_lake_smoke_test.sh
./scripts/23_minio_lake_smoke_test.sh
./scripts/19_audit_lake_layout.sh
./scripts/20_list_remote_assets.sh
./scripts/24_export_lake_client_env.sh
```

通过条件：

- 全部脚本以 `0` 退出
- `19_audit_lake_layout.sh` 显示 6 个 prefix 占位齐全、5 张元数据表存在
- `20_list_remote_assets.sh` 在 `/data/robot-dh/logs/` 下落一份 JSON 报告
- `24_export_lake_client_env.sh` 默认输出脱敏，不会把真实密码打到 stdout

### v1.5 scale / benchmark / Argo 验收

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

通过条件见 [10.7.6 v1.5 验收](#1076-v15-验收)。

### 如果 Docker 未安装

```bash
./scripts/02_install_docker.sh
```

### 验证 PostgreSQL

```bash
docker exec -it robot-dh-postgres pg_isready -U robot_dh_admin -d robot_dh
```

### 验证 Redis

```bash
docker exec -it robot-dh-redis redis-cli -a "$REDIS_PASSWORD" ping
```

### 验证 MinIO

```bash
docker compose ps
docker logs robot-dh-minio --tail=100
```

## 14. systemd 开机自启

当前不默认自动安装 systemd unit。

如果需要开机自启，执行：

```bash
cd /opt/robot-dh-infra
sudo cp systemd/robot-dh-infra.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable robot-dh-infra
sudo systemctl start robot-dh-infra
```

## 15. 常见故障与处理

### 1. docker permission denied

现象：

- `docker ps` 提示权限不足

处理：

- 重新登录
- 或执行 `newgrp docker`

### 2. docker compose not found

现象：

- `docker compose version` 不可用

处理：

- 执行 `./scripts/02_install_docker.sh`
- 本项目依赖的是 Docker Compose plugin，而不是旧版独立二进制 `docker-compose`

### 3. Docker 拉镜像超时

现象：

- `docker compose up` 拉取镜像失败
- 提示 Docker Hub 超时

处理：

- 检查 `/etc/docker/daemon.json`
- 检查 registry mirror 配置
- 这台服务器已经配置镜像加速，如果后续机器重装 Docker，需要同步考虑镜像加速问题

### 4. Postgres init 脚本没有执行

现象：

- 容器已起，但 `robot_dh` 数据库或 `robot_dh_app` 账号不存在

原因：

- `/data/robot-dh/postgres/data` 已不是空目录
- Docker entrypoint 没有再次运行 `docker-entrypoint-initdb.d`

处理：

- 重新执行 `./scripts/04_up.sh`
- 它会在容器启动后检测数据库是否缺失，并尝试补跑 `01_init_robot_dh.sh`

### 5. MinIO bucket 没创建

处理：

- 查看 `docker logs robot-dh-minio-init`
- 查看 `docker logs robot-dh-minio --tail=100`
- 必要时重新执行 `docker compose up -d minio-init`

### 6. Redis NOAUTH

原因：

- 使用了错误密码
- 忘了先导出 `ROBOT_DH_REDIS_URL`

处理：

- 检查 `.env`
- 检查 `client/robot-dh-remote.env`
- 执行 `docker exec -it robot-dh-redis redis-cli -a "$REDIS_PASSWORD" ping`

### 7. SSH tunnel 本地端口被占用

现象：

- `ssh -L ...` 无法绑定本地端口

处理：

- 停掉旧的 SSH tunnel 进程
- 或改用其他本地端口，并同步修改 WSL 环境变量

### 8. WSL 能连，但 kind Pod 不能连

原因：

- 你把连接方式建立在 WSL 本机的 `127.0.0.1` SSH tunnel 上
- Pod 无法使用这条本地 loopback 链路

处理：

- 改用 `BIND_ADDR=0.0.0.0`
- 配置公网 IP / DNS
- 加上安全组或 UFW 白名单
- 在 K8s Secret 中写公网地址，不要写 `127.0.0.1`

## 16. 当前建议

如果你现在要继续推进 `robot-data-harness` 主项目对接，建议按以下顺序做：

1. 先在 WSL 完成 SSH tunnel 模式的 CLI / FastAPI 接入
2. 用真实远端 PostgreSQL / MinIO / Redis 跑通一轮 dataset registry、artifact、report 流程
3. 确认变量名、bucket 名、数据库 URI 都稳定后，再推进 kind / K8s Pod 直连模式
4. 等数据量和持久化要求上来后，再单独规划 `/dev/vdb` 数据盘迁移方案