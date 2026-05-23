# WSL 公网直连接入清单

这份清单用于本地 WSL 不走 SSH tunnel，直接通过公网 IP / DNS 访问云端 `robot-dh-infra`。

当前服务器公网 IP / DNS：`PUBLIC_SERVER_IP_OR_DNS`

## 使用前提

- 云端 `BIND_ADDR` 已改为 `0.0.0.0`
- 云安全组已只对你的 `TRUSTED_CIDR` 开放 5432 / 6379 / 9000 / 9001
- 服务器 UFW 已按白名单模式放行相同端口
- 服务器 `./scripts/04_up.sh` 已把 `.env` 中的 PostgreSQL 允许来源同步进受控 `pg_hba.conf` 区块
- 你接受数据库、Redis、MinIO 不再只监听本机回环地址

## 服务器侧准备

```bash
cd /opt/robot-dh-infra
./scripts/04_up.sh
./scripts/06_healthcheck.sh
./scripts/10_print_client_env.sh --mode public --host PUBLIC_SERVER_IP_OR_DNS --show-secrets
./scripts/12_firewall_plan.sh --public-host PUBLIC_SERVER_IP_OR_DNS
```

如需实际应用 UFW：

```bash
cd /opt/robot-dh-infra
./scripts/12_firewall_plan.sh --apply --public-host PUBLIC_SERVER_IP_OR_DNS
```

如果你已经把 `TRUSTED_CIDR` 和 `SSH_TRUSTED_CIDR` 写进云端 `.env`，这里不需要再手动带占位符参数。

## WSL 侧准备

把以下文件拷到 WSL 项目可访问的位置：

- `client/robot-dh-public.env`
- `client/wsl-export-public-env.sh`
- `client/wsl-remote-doctor.sh`

加载环境变量：

```bash
source ./wsl-export-public-env.sh
```

做一次体检：

```bash
./wsl-remote-doctor.sh
```

## WSL 直连验证

```bash
psql "$ROBOT_DH_DB_URI" -c 'select current_database(), current_user;'
redis-cli -u "$ROBOT_DH_REDIS_URL" ping
curl -fsS "$ROBOT_DH_S3_ENDPOINT_URL/minio/health/live"
```

## 明确不要做的事

- 不要再使用 `127.0.0.1:15432` / `19000` / `16379`
- 不要再依赖 SSH tunnel
- 不要在主项目里回退到 SQLite / PVC / 本地 artifacts 路径
- 不要把 5432 / 6379 / 9000 / 9001 开放给 `0.0.0.0/0`

## WSL 出口 IP 变更后的增量放行（高频踩坑）

WSL2 / 公司 NAT / 移动网络的出口 IP 经常变。一旦变了，旧 IP 还在 ufw 白名单里，新 IP 会被 drop，外部表现是：

- `psql` / `redis-cli` 连接超时
- `curl http://PUBLIC_HOST:9000/minio/health/live` 报 `Empty reply from server` 或 `Connection was closed before we received a valid response`
- 在 Argo / kind Pod 里 S3 client 报 `EndpointConnectionError` 或 `RemoteDisconnected`

### 1. 在 WSL host 获取当前出口 IP

```bash
curl -4 ipv4.icanhazip.com
# 例：118.240.55.49
```

### 2. 在云端服务器增量放行（**只追加，不动旧规则**）

```bash
# ssh 上云端服务器，把上一步拿到的 IP 替换进去
WSL_EGRESS_IP=<上一步输出的 IP>
for port in 5432 6379 9000 9001; do
  sudo ufw allow from "$WSL_EGRESS_IP" to any port "$port" proto tcp \
    comment "wsl_egress_$(date +%Y%m%d)"
done
sudo ufw status numbered
```

> 不要用 `./scripts/12_firewall_plan.sh --apply` 处理这种增量场景——那个脚本会同时 `--force enable` 并清掉宽 SSH 规则，副作用比一行 `ufw allow` 大。raw `ufw allow` 是幂等的（重复加同一条规则会被 dedupe）。

### 3. 腾讯云安全组同步（如果用了 IP 白名单模式）

如果云控制台的"安全组"页面对 5432 / 6379 / 9000 / 9001 也设了来源 IP 白名单，记得在那一层也加上新的 `WSL_EGRESS_IP/32`。仅放行 ufw 而漏掉安全组，仍然会被云端 SDN 在到达虚机前就丢包。

### 4. WSL 侧立刻验证

```bash
# 替换 PUBLIC_HOST 为实际公网 IP / DNS
curl -fsS --max-time 5 http://PUBLIC_HOST:9000/minio/health/live -o /dev/null -w "HTTP %{http_code}\n"
psql "$ROBOT_DH_DB_URI" -Atqc 'select 1;'
redis-cli -u "$ROBOT_DH_REDIS_URL" ping
./wsl-remote-doctor.sh
```

四步全过 → 重新 submit Argo Workflow / 跑 scale plan。

### 5. 清理过期的白名单（可选，定期做）

```bash
# 列出现有规则编号，找到不再使用的旧 WSL IP 那几行
sudo ufw status numbered
# 按编号倒序删除（避免编号漂移）
sudo ufw delete <N>
```