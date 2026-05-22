#!/usr/bin/env bash
set -euo pipefail

as_root() {
  if [[ ${EUID} -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

target_uid() {
  if [[ -n "${SUDO_UID:-}" ]]; then
    printf '%s\n' "$SUDO_UID"
  else
    id -u
  fi
}

target_gid() {
  if [[ -n "${SUDO_GID:-}" ]]; then
    printf '%s\n' "$SUDO_GID"
  else
    id -g
  fi
}

OWNER_UID=$(target_uid)
OWNER_GID=$(target_gid)

declare -a all_dirs=(
  /data
  /data/robot-dh
  /data/robot-dh/datasets
  /data/robot-dh/datasets/raw
  /data/robot-dh/datasets/raw/droid
  /data/robot-dh/datasets/raw/droid/calibration
  /data/robot-dh/datasets/raw/droid/lerobot_sample
  /data/robot-dh/datasets/raw/bridgedata_v2
  /data/robot-dh/datasets/raw/bridgedata_v2/sample
  /data/robot-dh/datasets/raw/robomimic
  /data/robot-dh/datasets/raw/robomimic/sample
  /data/robot-dh/datasets/staging
  /data/robot-dh/datasets/manifests
  /data/robot-dh/cache
  /data/robot-dh/cache/huggingface
  /data/robot-dh/cache/openxlab
  /data/robot-dh/cache/github
  /data/robot-dh/postgres
  /data/robot-dh/postgres/data
  /data/robot-dh/postgres/backups
  /data/robot-dh/minio
  /data/robot-dh/minio/data
  /data/robot-dh/minio/backups
  /data/robot-dh/redis
  /data/robot-dh/redis/data
  /data/robot-dh/logs
  /data/robot-dh/tmp
)

for dir_path in "${all_dirs[@]}"; do
  as_root mkdir -p "$dir_path"
done

as_root chmod 0755 /data /data/robot-dh /data/robot-dh/datasets /data/robot-dh/cache /data/robot-dh/postgres /data/robot-dh/minio /data/robot-dh/redis
as_root chmod 0777 \
  /data/robot-dh/postgres/data \
  /data/robot-dh/postgres/backups \
  /data/robot-dh/minio/data \
  /data/robot-dh/minio/backups \
  /data/robot-dh/redis/data \
  /data/robot-dh/logs
as_root chmod 1777 /data/robot-dh/tmp
as_root chown "$OWNER_UID:$OWNER_GID" \
  /data/robot-dh/datasets \
  /data/robot-dh/cache \
  /data/robot-dh/postgres/backups \
  /data/robot-dh/minio/backups \
  /data/robot-dh/logs \
  /data/robot-dh/tmp

as_root chown -R "$OWNER_UID:$OWNER_GID" \
  /data/robot-dh/datasets \
  /data/robot-dh/cache

echo "== Disk Layout =="
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS
echo
df -h
echo
findmnt -T /
findmnt -T /data
echo

root_source=$(findmnt -nro SOURCE -T /)
data_source=$(findmnt -nro SOURCE -T /data)
if [[ "$data_source" == "$root_source" ]]; then
  echo "WARNING: No dedicated data disk detected; using root filesystem for /data/robot-dh."
fi

root_parent=$(lsblk -no PKNAME "$root_source" 2>/dev/null || true)
mapfile -t unmounted_devices < <(lsblk -rpn -o NAME,TYPE,MOUNTPOINT | awk '$2 ~ /^(disk|part)$/ && $3 == "" { print $1 }')

extra_devices=()
for device in "${unmounted_devices[@]}"; do
  device_parent=$(lsblk -no PKNAME "$device" 2>/dev/null || true)
  if [[ "$device" == "$root_source" || "$device" == "/dev/$root_parent" || "$device_parent" == "$root_parent" ]]; then
    continue
  fi
  extra_devices+=("$device")
done

if ((${#extra_devices[@]} > 0)); then
  echo "Unmounted block devices detected:"
  printf '  %s\n' "${extra_devices[@]}"
  echo "Suggestion: attach and mount a dedicated data disk only after reviewing the partition and mount plan. No mkfs/parted/fdisk actions were performed."
else
  echo "No extra unmounted data disks were detected beyond the root device."
fi

echo
echo "Prepared infra and dataset directories under /data/robot-dh. No existing data was removed."