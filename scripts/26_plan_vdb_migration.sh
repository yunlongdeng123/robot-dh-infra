#!/usr/bin/env bash
set -euo pipefail

# v1.5 /dev/vdb 数据盘迁移计划生成器（read-only / plan-only）。
#
# 用途：
#   生成把 /data/robot-dh 迁移到挂载在 /dev/vdb 的新文件系统的人工命令清单。
#   仅打印计划与人工命令草案，永远不执行任何 destructive command。
#
# 安全约束（绝对禁止）：
#   - 不执行 mkfs / parted / fdisk / wipefs
#   - 不执行 mount / umount
#   - 不修改 /etc/fstab
#   - 不停止任何服务
#   - 不执行 rsync 或任何数据搬运
#
# 用法：
#   ./scripts/26_plan_vdb_migration.sh
#   ./scripts/26_plan_vdb_migration.sh --mount-target /data2/robot-dh
#
# 输出：
#   stdout 上的迁移计划草案
#   /data/robot-dh/logs/vdb_migration_plan_YYYYmmdd_HHMMSS.txt

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
ENV_FILE="$PROJECT_DIR/.env"

MOUNT_TARGET="/data2/robot-dh"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mount-target)
      shift
      [[ $# -gt 0 ]] || { echo "ERROR: --mount-target requires value" >&2; exit 1; }
      MOUNT_TARGET="$1"
      ;;
    -h|--help)
      echo "Usage: $0 [--mount-target /data2/robot-dh]" >&2
      exit 0
      ;;
    *)
      echo "ERROR: unknown arg: $1" >&2
      exit 1
      ;;
  esac
  shift
done

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE not found. Run ./scripts/03_generate_env.sh first." >&2
  exit 1
fi

LOG_ROOT="/data/robot-dh/logs"
mkdir -p "$LOG_ROOT"
TIMESTAMP=$(date -u +%Y%m%d_%H%M%S)
OUT_FILE="$LOG_ROOT/vdb_migration_plan_${TIMESTAMP}.txt"

current_used=$(du -sb /data/robot-dh 2>/dev/null | awk '{print $1}' || echo 0)
current_used_gib=$(awk -v b="$current_used" 'BEGIN{printf "%.2f", b/1024/1024/1024}')

vdb_exists="no"
vdb_size="-"
vdb_fstype="-"
vdb_mountpoint="-"
if [[ -b /dev/vdb ]]; then
  vdb_exists="yes"
  vdb_size=$(lsblk -bno SIZE /dev/vdb | head -n1 || echo "-")
  vdb_fstype=$(lsblk -no FSTYPE /dev/vdb | head -n1 | tr -d '[:space:]' || echo "")
  vdb_mountpoint=$(lsblk -no MOUNTPOINT /dev/vdb | head -n1 | tr -d '[:space:]' || echo "")
  [[ -z "$vdb_fstype" ]] && vdb_fstype="(none)"
  [[ -z "$vdb_mountpoint" ]] && vdb_mountpoint="(not mounted)"
fi

# 涉及到的服务（按 compose 设计）
SERVICES=(robot-dh-postgres robot-dh-minio robot-dh-redis)

render_plan() {
  cat <<EOF
================================================================================
/dev/vdb 数据盘迁移计划草案
generated_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)
plan_mode:    plan-only (本脚本不执行任何 destructive command)
================================================================================

【现状】
- 数据根目录：           /data/robot-dh
- 当前 /data/robot-dh 占用： ${current_used_gib} GiB (${current_used} bytes)
- /dev/vdb 是否存在：    ${vdb_exists}
- /dev/vdb 容量(bytes)： ${vdb_size}
- /dev/vdb 文件系统：    ${vdb_fstype}
- /dev/vdb 挂载点：      ${vdb_mountpoint}
- 推荐挂载点：           ${MOUNT_TARGET}

【涉及服务】
- 以下 docker 服务在迁移期间必须停机：
$(for s in "${SERVICES[@]}"; do echo "  - $s"; done)
- 备份脚本 / 应用客户端在迁移窗口内禁止访问数据目录。

【迁移前置条件】
- [ ] 已经在另一台机器上备份 PostgreSQL：./scripts/07_backup_postgres.sh
- [ ] 已经在另一台机器上备份 MinIO：./scripts/08_backup_minio.sh
- [ ] 已经将上述备份验证为可恢复（恢复演练通过）
- [ ] 已与依赖方约定停机窗口
- [ ] 已经记录当前 docker volumes / bind mount 路径

【人工命令草案 — 仅供 review，不要直接复制执行】

# 1. 检查 /dev/vdb 状态（再确认不会破坏现有 FS）
sudo lsblk /dev/vdb
sudo blkid /dev/vdb || true
sudo wipefs -n /dev/vdb || true        # n = no-act，只打印

# 2. （如确认 /dev/vdb 上没有任何想保留的数据）创建文件系统
#    !!! 这一步会清空 /dev/vdb，必须由人工二次确认后再执行 !!!
# sudo mkfs.ext4 -L robot-dh-data /dev/vdb

# 3. 创建挂载点并临时挂载，先做一次 rsync 试跑
sudo mkdir -p "${MOUNT_TARGET}"
# sudo mount /dev/vdb "${MOUNT_TARGET}"

# 4. 停服务（让 PostgreSQL / MinIO / Redis 静止）
cd ${PROJECT_DIR}
./scripts/05_down.sh

# 5. rsync 数据（保留属主 / 权限 / 时间戳；先 dry-run）
sudo rsync -aAXHv --delete --info=progress2 \\
  /data/robot-dh/ "${MOUNT_TARGET}/" \\
  --dry-run
# 确认无误后再去掉 --dry-run 跑一次。

# 6. 校验：体积应当与原目录一致
sudo du -sb /data/robot-dh
sudo du -sb "${MOUNT_TARGET}"

# 7. 切换符号链接（推荐：保留原 /data/robot-dh 路径）
sudo mv /data/robot-dh /data/robot-dh.legacy.${TIMESTAMP}
sudo ln -s "${MOUNT_TARGET}" /data/robot-dh

# 8. 写 fstab（建议使用 UUID，避免设备名漂移）
#    !!! 这一步会写系统文件，必须由人工 review 后才执行 !!!
# UUID=\$(sudo blkid -s UUID -o value /dev/vdb)
# echo "UUID=\${UUID}  ${MOUNT_TARGET}  ext4  defaults,noatime  0  2" | sudo tee -a /etc/fstab
# sudo mount -a
# sudo systemctl daemon-reload

# 9. 启服务并健康检查
cd ${PROJECT_DIR}
./scripts/04_up.sh
./scripts/06_healthcheck.sh

# 10. 观察 24 小时后清理 legacy（人工确认后再删）
# sudo rm -rf /data/robot-dh.legacy.${TIMESTAMP}

【回滚计划】

- 任意一步失败且服务尚未启动时，可直接：
    sudo umount "${MOUNT_TARGET}" || true
    sudo rm /data/robot-dh
    sudo mv /data/robot-dh.legacy.${TIMESTAMP} /data/robot-dh
    cd ${PROJECT_DIR}
    ./scripts/04_up.sh
- 已经启动并写入新数据后，必须先停服务、从备份恢复 PostgreSQL / MinIO，才能切回旧目录。

【验收】
- df -h /data/robot-dh 显示挂载在 /dev/vdb 而不是 /dev/vda*
- ./scripts/06_healthcheck.sh 全部通过
- ./scripts/19_audit_lake_layout.sh 全部通过
- robot-data-harness 主项目端能正常 lake 查询

================================================================================
重要提醒
- 本脚本只生成计划；它**不会**自动执行 mkfs / mount / rsync / fstab 修改。
- 任何带 "sudo mkfs" / "sudo mount" / "tee -a /etc/fstab" 的步骤必须由人工
  逐条确认后再手动执行。
- 在执行前请通读 docs/v1_5_storage_plan.md。
================================================================================
EOF
}

render_plan | tee "$OUT_FILE"

echo
echo "Migration plan written to: $OUT_FILE"
