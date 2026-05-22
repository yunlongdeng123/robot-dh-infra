# robot-dh-infra v1.5 Argo Workflows 远程接入

本文说明如何把云端 `robot-dh-infra`（PostgreSQL / MinIO / Redis）的连接信息注入到 WSL/kind 上的 Argo Workflows Pod。

> Argo Workflows 控制面由 WSL/kind 项目部署，本仓库**不安装** argo-server / workflow-controller。本仓库只提供 namespace / ServiceAccount / RBAC / Secret 模板，以及一份 env 模板。

## 1. 接入拓扑

```
+--------------------------+     公网 / VPC      +-----------------------------+
| WSL / kind (Argo + Pods) |  <--------------->  |  腾讯云 Ubuntu (robot-dh)   |
| - argo-server            |     5432 / 9000     |  - PostgreSQL :5432         |
| - workflow-controller    |     6379            |  - MinIO       :9000        |
| - robot-data-harness     |                     |  - Redis       :6379        |
|   step pods (rdh-app)    |                     |  - robot-dh-infra docker    |
+--------------------------+                     +-----------------------------+
```

关键限制：

- WSL host 可以用 SSH tunnel 把云端端口暴露到 `127.0.0.1:15432 / 19000 / 16379`，但这只对 WSL host 本机进程生效。
- kind / Argo Pod **不能**通过 `127.0.0.1` 命中 WSL host 上的 tunnel —— Pod 的 `127.0.0.1` 指向 Pod 自己。
- 所以 Argo Workflows Pod 注入的 endpoint 必须是云端**公网 IP/DNS**，且这些端口已经在云端 [`scripts/12_firewall_plan.sh`](../scripts/12_firewall_plan.sh) 通过白名单 CIDR 放行。

## 2. 所需环境变量

| 变量 | 含义 | 示例 |
|------|------|------|
| `ROBOT_DH_RELEASE_VERSION` | 版本号，便于 step pod 上报 | `v1.5` |
| `ROBOT_DH_ARGO_NAMESPACE` | Argo workflow 落地的 namespace | `robot-dh` |
| `ROBOT_DH_DB_URI` | PostgreSQL 应用账号连接串 | `postgresql+psycopg://robot_dh_app:***@HOST:5432/robot_dh` |
| `ROBOT_DH_ARTIFACT_STORE` | `s3` 固定值 | `s3` |
| `ROBOT_DH_S3_ENDPOINT_URL` | MinIO HTTP endpoint | `http://HOST:9000` |
| `ROBOT_DH_S3_ACCESS_KEY` | MinIO 应用 access key | `robotdhapp` |
| `ROBOT_DH_S3_SECRET_KEY` | MinIO 应用 secret | `***` |
| `ROBOT_DH_S3_DATA_BUCKET` | raw 数据 bucket | `robot-datasets` |
| `ROBOT_DH_S3_ARTIFACT_BUCKET` | quality artifacts bucket | `robot-dh-artifacts` |
| `ROBOT_DH_S3_BACKUP_BUCKET` | 备份 bucket | `robot-dh-backups` |
| `ROBOT_DH_S3_LAKE_BUCKET` | lake bucket | `robot-lake` |
| `ROBOT_DH_REDIS_URL` | Redis URL（包含密码） | `redis://:***@HOST:6379/0` |

## 3. 在云端生成 env

```bash
cd /opt/robot-dh-infra

# 脱敏预览
./scripts/31_argowf_remote_env_export.sh

# 写真实文件（chmod 600，不要提交到 git）
./scripts/31_argowf_remote_env_export.sh --show-secrets
# => client/robot-dh-v1-5.env

# 可选：tunnel 模式（仅限 WSL host 本机进程，不能用于 Pod）
./scripts/31_argowf_remote_env_export.sh --mode tunnel --show-secrets
```

`stdout` 永远只输出脱敏值；`--show-secrets` 仅写入文件。把文件 `scp` 到 WSL host 时使用 `scp -p` 保留 `0600` 权限。

## 4. 在 WSL host 注入 Secret

```bash
# 1. 在 WSL host 把 namespace / ServiceAccount / RBAC 一次性创建
kubectl apply -f /path/to/robot-dh-infra/client/k8s-argo-secret.example.yaml

# 2. 把云端生成的 env 文件放到 WSL（注意权限）
chmod 600 client/robot-dh-v1-5.env

# 3. 注入 Secret（不打印任何明文）
set -a; source client/robot-dh-v1-5.env; set +a

PUBLIC_HOST=<云端公网 IP/DNS> \
ROBOT_DH_APP_PASSWORD=<应用账号密码> \
MINIO_APP_SECRET_KEY=<MinIO secret> \
REDIS_PASSWORD=<Redis password> \
./client/k8s-create-argo-secret.example.sh
```

`k8s-create-argo-secret.example.sh` 默认拒绝 `127.0.0.1` / `localhost` 作为 `PUBLIC_HOST`，因为 Pod 内的 `127.0.0.1` 不会进入 WSL host tunnel。仅当你确实在 WSL host 上用单进程做最小集成测试时，可加 `--allow-localhost`。

## 5. 在 Argo Workflow 引用 Secret

WorkflowTemplate / Workflow 中典型用法：

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
        command: ["robot-dh"]
        args: ["etl", "run", "--phase", "normalize", "--dataset", "{{workflow.parameters.dataset}}"]
```

注意：

- `serviceAccountName` 使用 `robot-dh-argo`，绑定的 Role 在 `k8s-argo-secret.example.yaml` 中定义
- `envFrom.secretRef` 把所有 `ROBOT_DH_*` 变量挂入容器，与 robot-data-harness CLI 的环境读取约定一致
- step container 必须能通过 DNS 解析云端 `PUBLIC_HOST`，并能直连 5432/9000/6379；如有 NAT / 防火墙，请先在 [`12_firewall_plan.sh`](../scripts/12_firewall_plan.sh) 中放行 WSL/kind 出口 IP

## 6. 故障排查

| 现象 | 可能原因 | 排查 |
|------|----------|------|
| Pod 启动后立刻退出，日志没有连接错误 | secret 未挂载或字段名不对 | `kubectl -n robot-dh get secret robot-dh-v1-5-secrets -o jsonpath='{.data}' \| jq 'keys'` |
| `psycopg.OperationalError: connection refused` | `127.0.0.1` 进了 Secret；或防火墙没放行 | 重新跑 `31_argowf_remote_env_export.sh`，并检查云端 ufw / 安全组 |
| `botocore.exceptions.EndpointConnectionError` | MinIO endpoint 不可达；Pod 没法解析 DNS | 在 Pod 内 `kubectl exec ... -- curl -v http://HOST:9000/minio/health/live` |
| `redis.exceptions.AuthenticationError` | Redis 密码不一致或被 tunnel 拦截 | 在云端跑 `06_healthcheck.sh` 验证 Redis；再用 `redis-cli -h HOST -p 6379 -a $REDIS_PASSWORD ping` |
| Pod `Forbidden: pods is forbidden` | ServiceAccount / RBAC 没装 | `kubectl apply -f client/k8s-argo-secret.example.yaml` |

## 7. 安全建议

- `client/robot-dh-v1-5.env` 必须 `chmod 600` 并加入 `.gitignore`（仓库 `.gitignore` 已覆盖 `client/*.env`，但请二次确认）。
- Argo Workflow 输出物（日志 / WorkflowTaskResult）不要回包含连接串；rdh-app 默认会 mask `ROBOT_DH_S3_SECRET_KEY` 等字段。
- 公网直连仅适用于受限的 WSL/kind 开发场景。生产部署应改走 VPC / 专线 / 私网域名。
