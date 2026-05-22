# robot-dh v1.4 数据湖基础设施 runbook

本 runbook 是 v1.4 数据湖基础设施的操作手册，覆盖初始化顺序、健康检查、资产发现、客户端 env 导出、K8s Secret 注入、回滚和常见故障。它不替代 README，只补 v1.4 的细节。

约定：

- 所有命令默认在云端服务器（`/opt/robot-dh-infra`）以 `ubuntu` 用户身份运行。
- 所有脚本都 `set -euo pipefail`，可重复执行；任何失败都会非零退出。
- 任何脚本都不会主动删除已有对象、表或数据，也不会改防火墙规则。

## 1. 前置条件

执行 v1.4 脚本前，请先确认 v1.3 基础设施已经就绪：

```bash
cd /opt/robot-dh-infra
./scripts/06_healthcheck.sh
```

`06_healthcheck.sh` 必须全部通过：

- `docker compose ps`：四个容器（postgres / minio / minio-init / redis）状态健康
- `postgres pg_isready` 返回 `accepting connections`
- `redis PING` 返回 `PONG`
- `minio health` 返回 200
- `minio bucket list` 至少包含 `robot-datasets`、`robot-dh-artifacts`、`robot-dh-backups`

如果 `robot-lake` 还没创建，这一步不会报错；它会在 `18_setup_lake_buckets.sh` 中补齐。

## 2. 初始化顺序（v1.4 增量）

推荐顺序：

```bash
cd /opt/robot-dh-infra

# 1) 确认基础设施健康
./scripts/06_healthcheck.sh

# 2) 创建 robot-lake bucket、开启 versioning、写占位对象、应用 lake policy
./scripts/18_setup_lake_buckets.sh

# 3) 应用 lake 元数据 schema（lake_assets / etl_jobs / lineage_edges / dataset_versions / quality_snapshots）
./scripts/21_pg_apply_lake_schema.sh

# 4) PostgreSQL smoke：应用账号能 INSERT + DELETE 五张表
./scripts/22_pg_lake_smoke_test.sh

# 5) MinIO smoke：应用账号能 PUT + STAT + DELETE robot-lake/tmp/ 下对象
./scripts/23_minio_lake_smoke_test.sh

# 6) 数据湖布局审计（bucket / prefix / versioning / 元数据表 / 磁盘）
./scripts/19_audit_lake_layout.sh

# 7) 扫描远端已有数据资产（robot-datasets/raw、robot-lake/raw）
./scripts/20_list_remote_assets.sh

# 8) 输出脱敏版 lake 客户端 env，确认变量名一致
./scripts/24_export_lake_client_env.sh
```

补充：

- `18_setup_lake_buckets.sh` 内部使用 `mc mb --ignore-existing`，反复执行不会破坏现有对象。
- `21_pg_apply_lake_schema.sh` 是 `CREATE TABLE IF NOT EXISTS`，幂等。
- `22_pg_lake_smoke_test.sh` 会在一个事务中写五条记录并立刻删除，不会污染数据。
- `23_minio_lake_smoke_test.sh` 只会写到 `robot-lake/tmp/smoke_*/health.txt` 并立刻删除。

## 3. 健康检查

v1.4 自带的轻量审计入口是 `19_audit_lake_layout.sh`，覆盖：

- MinIO bucket `robot-lake` 是否存在
- prefix 占位：`raw/.keep`、`ods/.keep`、`dwd/.keep`、`ads/quality/.keep`、`lineage/events/.keep`、`tmp/.keep`
- bucket versioning 状态（输出 `mc version info`）
- PostgreSQL 五张元数据表是否存在
- `/data/robot-dh` 磁盘使用（`df -h`、`du -sh /data/robot-dh/*`）

任何一项失败都会让脚本以非零退出，并打印明确的 `ERROR:` 或 `RAISE EXCEPTION`。

## 4. 如何发现远端已有资产

`20_list_remote_assets.sh` 用于在不依赖白名单的情况下扫描云端 MinIO，发现已经放上去的数据资产：

```bash
cd /opt/robot-dh-infra
./scripts/20_list_remote_assets.sh
```

它会：

1. 用 root 凭据 `mc ls --recursive --json` 扫 `robot-datasets/raw/` 和 `robot-lake/raw/`。
2. 按 `{dataset_id}/{version}/` 聚合候选目录。
3. 对每个候选检查 `endpose.pt`、`video.mp4`、`meta.yaml` 是否存在。
4. 输出：
   - 人类可读表格到 stdout
   - JSON 报告到 `/data/robot-dh/logs/remote_assets_YYYYmmdd_HHMMSS.json`

如果当前 MinIO 中没有任何候选目录，脚本会打印 `No candidate dataset directories were discovered ...` 并正常退出，不会失败。

## 5. 如何给 WSL 项目导出 env

v1.3 已有 `10_print_client_env.sh`；v1.4 增加了一个面向数据湖的版本 `24_export_lake_client_env.sh`。两者的差异是 v1.4 额外注入了 `ROBOT_DH_ARTIFACT_STORE` 和 `ROBOT_DH_S3_LAKE_BUCKET`。

### 默认行为：脱敏

```bash
cd /opt/robot-dh-infra
./scripts/24_export_lake_client_env.sh
```

输出会把所有密码/secret 打码成 `xxxx****xxxx`，方便对照变量名拷给同事，不会写文件。

### 写真实 env 文件

```bash
cd /opt/robot-dh-infra
./scripts/24_export_lake_client_env.sh --show-secrets
```

会写入 `client/robot-dh-lake.env`，权限 `0600`。

### 切换 SSH tunnel / 公网模式

```bash
# SSH tunnel，host=127.0.0.1，端口 15432/19000/16379
./scripts/24_export_lake_client_env.sh --mode tunnel --show-secrets

# 公网直连，自动探测 host
./scripts/24_export_lake_client_env.sh --mode public --show-secrets

# 公网直连，显式指定 host
./scripts/24_export_lake_client_env.sh --mode public --host robot-dh.example.com --show-secrets
```

WSL 侧使用方式：

```bash
set -a
source ./client/robot-dh-lake.env
set +a
```

然后即可在主项目 `robot-data-harness` 中读取 `ROBOT_DH_DB_URI` / `ROBOT_DH_S3_*` / `ROBOT_DH_REDIS_URL`。

## 6. 如何给 kind 注入 K8s Secret

参考 `client/k8s-lake-secret.example.yaml` 和 `client/k8s-create-lake-secret.example.sh`：

```bash
# 1) 确认 kubectl 当前 context 指向目标 kind 集群
kubectl config current-context

# 2) 确认 namespace 存在
kubectl get ns robot-dh || kubectl create namespace robot-dh

# 3) 从环境变量注入真实值，然后用 kubectl apply 创建 / 更新 Secret
ROBOT_DH_APP_PASSWORD=...     \
MINIO_APP_SECRET_KEY=...      \
REDIS_PASSWORD=...            \
PUBLIC_HOST=robot-dh.example.com \
./client/k8s-create-lake-secret.example.sh
```

注意：

- kind Pod 不能走 WSL 本地 SSH tunnel，必须用云服务器公网 IP / DNS。
- 必须先满足 README 第 10 章 "kind / K8s 接入清单"（开放 `BIND_ADDR`、设置 `TRUSTED_CIDR`、应用 firewall plan）。
- Secret 名默认 `robot-dh-lake-secrets`，可通过 `SECRET_NAME` 覆盖。

## 7. 如何回滚

v1.4 基础设施层不删数据，所以回滚只删元数据控制面，不删 bucket 对象。

### 7.1 卸载 v1.4 PostgreSQL 元数据表

通常不需要做这一步；v1.4 表是增量创建的，不影响 v1.3。如果实在要清掉测试数据：

```bash
docker exec -it robot-dh-postgres \
  psql -U robot_dh_admin -d robot_dh -c '
    BEGIN;
    DROP TABLE IF EXISTS quality_snapshots;
    DROP TABLE IF EXISTS lineage_edges;
    DROP TABLE IF EXISTS etl_jobs;
    DROP TABLE IF EXISTS lake_assets;
    DROP TABLE IF EXISTS dataset_versions;
    COMMIT;'
```

仅限确认 v1.4 元数据表为空时执行。

### 7.2 暂停 MinIO `robot-lake` 写入

如果需要暂时阻断对 lake bucket 的写入，最稳的方式是吊销 lake policy：

```bash
docker run --rm --entrypoint sh --network robot-dh-net \
  -e MINIO_ROOT_USER -e MINIO_ROOT_PASSWORD \
  minio/mc:latest -c '
    mc alias set local http://robot-dh-minio:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null
    mc admin policy detach local robot-dh-lake-readwrite --user "$MINIO_APP_ACCESS_KEY"
  '
```

恢复时重新执行 `./scripts/18_setup_lake_buckets.sh`，它会再次 attach 该 policy。

### 7.3 不要做的事

- 不要 `mc rb --force local/robot-lake`：会清空已上传的数据。
- 不要 `DROP DATABASE robot_dh`：会破坏 v1.3 registry。
- 不要在保留 versioning 的 bucket 上手工运行 `mc rm --recursive`：会创建删除标记，回放困难。

## 8. 常见故障

### 8.1 `ERROR: Could not connect to MinIO ...`

可能原因：

- MinIO 容器未启动 / 健康检查未通过。
- root 凭据被改过，未同步到 `.env`。
- 自定义网络 `robot-dh-net` 被删除（升级 Compose 时偶发）。

处理：

```bash
docker compose ps
docker logs robot-dh-minio --tail=100
./scripts/04_up.sh
./scripts/06_healthcheck.sh
```

### 8.2 `Missing lake metadata tables: ...`

原因：忘了执行 `21_pg_apply_lake_schema.sh`，或者执行时连接到了别的库。

处理：

```bash
cd /opt/robot-dh-infra
./scripts/21_pg_apply_lake_schema.sh
./scripts/22_pg_lake_smoke_test.sh
```

### 8.3 `mc: <ERROR> Unable to ... Access Denied.`

原因：

- 应用账号 `MINIO_APP_ACCESS_KEY` 没绑上 `robot-dh-lake-readwrite` policy。
- 容器内 `mc` 版本太旧，`mc admin policy attach` 命令不可用。

处理：

```bash
./scripts/18_setup_lake_buckets.sh
./scripts/23_minio_lake_smoke_test.sh
```

如果 `18` 输出 `WARNING: Could not attach lake policy ...`，请检查 minio/mc 镜像是否被 pin 到过老版本；当前要求使用 `minio/mc:latest`。

### 8.4 `20_list_remote_assets.sh` 输出空表

可能原因：

- 服务器上还没人把数据资产 push 到 `robot-datasets/raw/...` 或 `robot-lake/raw/...`。
- 数据被放在了非 `raw/` 前缀下（例如 `robot-datasets/curated/...`）。
- 数据资产命名层级不是 `{dataset_id}/{version}/` 两级，被脚本过滤掉。

处理：先用 `mc ls --recursive local/robot-datasets/` 确认数据实际位置，再决定要不要扩展扫描脚本的入口前缀。

### 8.5 `client/robot-dh-lake.env` 没生成

`24_export_lake_client_env.sh` 默认是脱敏模式，不写文件。必须显式带 `--show-secrets` 才会写。

```bash
./scripts/24_export_lake_client_env.sh --show-secrets
ls -l client/robot-dh-lake.env
```

文件权限应为 `0600`；如果文件落到了其他位置，请确认是否在 `/opt/robot-dh-infra` 下执行的脚本。

## 9. 验收清单

以下命令必须全部成功，作为 v1.4 数据湖基础设施的验收依据：

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

- 全部以 `0` 退出。
- `19_audit_lake_layout.sh` 显示 6 个 prefix 占位齐全、5 张元数据表存在。
- `20_list_remote_assets.sh` 在 `/data/robot-dh/logs/` 下落了一份 JSON 报告。
- `24_export_lake_client_env.sh` 默认输出是脱敏的，没有把真实密码打到 stdout。
