# v1.6 本地 WSL 远端依赖闭环记录

> 本文件记录本地 WSL v1.6 开发闭环中，`robot-dh-infra` 侧已经补齐的远端依赖，以及仍然不能在当前环境自动执行的项目。
> 更新时间：2026-05-24。

---

## 当前结论

当前 WSL 环境里的 Docker 依赖已经可用：`robot-dh-postgres`、`robot-dh-minio`、`robot-dh-redis` 均处于 healthy 状态。v1.6 PostgreSQL schema 已经在本地实例上幂等应用，应用账号写入 smoke test 已通过；v1.6 审计、workflow metadata、QC contract、tmp lifecycle 报告都已生成。

当前仍未完成的是 K8s / Argo 集群提交和真实多源数据处理：本机缺少 `kubectl`、`kind`、`argo`，且本仓库不包含 `robot-data-harness` 的 `make argo-*`、`robot-dh normalize`、`robot-dh qc contract run`、`robot-dh ml-ready export` 等业务命令。

## 已完成项

| 类别 | 结果 | 已执行 / 可复跑命令 |
|---|---|---|
| Docker 依赖 | PostgreSQL / MinIO / Redis 均 healthy | `bash scripts/06_healthcheck.sh` |
| Postgres DDL | `005_v1_6_robot_platform.sql` 已应用，9 张 v1.6 表存在 | `bash scripts/35_pg_apply_v1_6_schema.sh` |
| Postgres rw | 应用账号 `robot_dh_app` 可对 9 张 v1.6 表 insert/delete | `bash scripts/36_pg_v1_6_smoke_test.sh` |
| 平台状态审计 | 已生成 JSON 报告 | `bash scripts/37_audit_v1_6_platform_state.sh` |
| Workflow metadata 报告 | 已生成 Markdown 报告；空 v1.6 业务数据不视为失败 | `bash scripts/38_workflow_metadata_report.sh` |
| QC contract 报告 | 已生成 Markdown 报告；空 contract/run 不视为失败 | `bash scripts/39_qc_contract_report.sh` |
| tmp lifecycle 审计 | read-only 审计已完成，未删除对象 | `bash scripts/40_storage_tmp_lifecycle_audit.sh` |
| 本地 client env 输出 | 已验证脱敏输出；真实文件已存在且权限为 `0600` | `bash scripts/41_export_v1_6_client_env.sh --host 127.0.0.1` |

本次生成的报告路径：

- `/data/robot-dh/logs/v1_6_platform_state_20260524_051928.json`
- `/data/robot-dh/logs/v1_6_workflow_metadata_report_20260524_051930.md`
- `/data/robot-dh/logs/v1_6_qc_contract_report_20260524_051930.md`
- `/data/robot-dh/logs/v1_6_storage_tmp_lifecycle_20260524_051931.md`

## 本地 WSL 复跑顺序

```bash
cd /home/ubuntu/robot-dh-infra

bash scripts/06_healthcheck.sh
bash scripts/35_pg_apply_v1_6_schema.sh
bash scripts/36_pg_v1_6_smoke_test.sh
bash scripts/37_audit_v1_6_platform_state.sh
bash scripts/38_workflow_metadata_report.sh
bash scripts/39_qc_contract_report.sh
bash scripts/40_storage_tmp_lifecycle_audit.sh
```

给本地 WSL 上的 v1.6 开发项目使用直连本机 Docker 端口时，使用：

```bash
bash scripts/41_export_v1_6_client_env.sh --host 127.0.0.1
```

如果需要把真实凭据写到 `client/robot-dh-v1-6.env`，再显式执行：

```bash
bash scripts/41_export_v1_6_client_env.sh --host 127.0.0.1 --show-secrets
chmod 600 client/robot-dh-v1-6.env
```

> 注意：`--show-secrets` 会覆盖 `client/robot-dh-v1-6.env`。本次只验证了脱敏输出，没有覆盖已有真实 env 文件。

## 仍需跳过 / 人工补齐项

### 1. K8s Secret 与 Argo submit

- 当前状态：未执行。
- 阻塞原因：当前 WSL 环境缺少 `kubectl`、`kind`、`argo`。
- 影响范围：不能在本仓库内完成 `kubectl apply`、Secret 注入、Argo workflow submit / sync。
- 补齐后执行：

```bash
kubectl apply -f client/k8s-v1-6-secret.example.yaml
set -a; source client/robot-dh-v1-6.env; set +a
bash client/k8s-create-v1-6-secret.example.sh
```

### 2. 真实多源数据处理

- 当前状态：未执行。
- 阻塞原因：`robot-dh-infra` 只负责本地服务、schema、审计脚本和 client 模板；真实 `normalize`、QC contract、ML-ready export 属于 `robot-data-harness` 主项目命令。
- 依赖数据：
  - `s3://robot-datasets/raw/droid_lerobot_scale30/v1`
  - `s3://robot-datasets/raw/robomimic_scale30/v1`
  - `s3://robot-datasets/raw/bridge_scale30/v1`

在主项目里恢复时，先 source 本仓库导出的 env，再执行对应 v1.6 业务命令。

### 3. exporter K8s 部署

- 当前状态：未执行。
- 阻塞原因：当前仓库没有 Go exporter 工程与 K8s 部署入口，本机也没有 kind 工具链。
- 补齐条件：在包含 exporter 的项目中完成 image build、kind load、K8s apply。

## 给主项目的 env 接入方式

本地 WSL 主项目如果直接连接当前 Docker 端口，使用 `--host 127.0.0.1` 生成的变量；端口应为：

- PostgreSQL：`127.0.0.1:5432`
- MinIO：`127.0.0.1:9000`
- Redis：`127.0.0.1:6379`

如果主项目走 SSH tunnel，则使用：

```bash
bash scripts/41_export_v1_6_client_env.sh --mode tunnel
```

tunnel 模式端口为 `15432 / 19000 / 16379`，必须先由外部 SSH tunnel 转发到真实远端服务，否则主项目无法连通。
