# WSL 接入清单

这份清单用于把本地 WSL 中的 `robot-data-harness` 接到云服务器上的 `robot-dh-infra`。

## 适用场景

适合：

- WSL 内本地 CLI 调试
- WSL 内本地 FastAPI 调试
- 本地手动回放 validator 流程

不适合：

- kind Pod 直连
- K8s Job / CronJob 通过 WSL 本地 `127.0.0.1` tunnel 访问云端

## 步骤 1：确认远端服务健康

在云服务器执行：

```bash
cd /opt/robot-dh-infra
./scripts/06_healthcheck.sh
```

## 步骤 2：获取 tunnel 命令

在云服务器执行：

```bash
cd /opt/robot-dh-infra
./scripts/11_print_ssh_tunnel.sh
```

默认转发：

- `15432 -> PostgreSQL 5432`
- `19000 -> MinIO S3 API 9000`
- `19001 -> MinIO Console 9001`
- `16379 -> Redis 6379`

## 步骤 3：在 WSL 打开 SSH tunnel

如果 WSL 有本地仓库副本：

```bash
SSH_HOST=robot-dh-tencent \
SSH_USER=ubuntu \
./client/wsl-open-tunnels.sh
```

否则直接运行打印出来的 `ssh -N -L ...` 命令。

可选变量：

- `SSH_PORT`
- `SSH_IDENTITY_FILE`

## 步骤 4：准备环境变量

在云服务器生成真实变量：

```bash
cd /opt/robot-dh-infra
./scripts/10_print_client_env.sh --show-secrets
```

该命令会生成两个真实文件：

- `client/robot-dh-remote.env`
- `client/wsl-export-env.sh`

或在 WSL 先用模板占位：

```bash
source ./client/wsl-export-env.example.sh
```

## 步骤 5：在 WSL 验证连通性

```bash
source ./wsl-export-env.sh
psql "$ROBOT_DH_DB_URI" -c 'select current_database(), current_user;'
redis-cli -u "$ROBOT_DH_REDIS_URL" ping
curl -fsS "$ROBOT_DH_S3_ENDPOINT_URL/minio/health/live"
```

如果你希望一次性做总检查，也可以执行：

```bash
source ./wsl-export-env.sh
./wsl-remote-doctor.sh
```

## 步骤 6：接入主项目

在运行 `robot-data-harness` CLI、FastAPI 或本地脚本之前，确保以下变量已导入：

- `ROBOT_DH_DB_URI`
- `ROBOT_DH_S3_ENDPOINT_URL`
- `ROBOT_DH_S3_ACCESS_KEY`
- `ROBOT_DH_S3_SECRET_KEY`
- `ROBOT_DH_S3_DATA_BUCKET`
- `ROBOT_DH_S3_ARTIFACT_BUCKET`
- `ROBOT_DH_REDIS_URL`

## 步骤 7：如果需要 kind / K8s Pod 访问

不要使用本地 tunnel 端口；改用：

- `BIND_ADDR=0.0.0.0`
- 公网 IP / DNS
- 安全组 / UFW 白名单
- `client/k8s-secret.example.yaml`
- `client/k8s-create-remote-secret.example.sh`