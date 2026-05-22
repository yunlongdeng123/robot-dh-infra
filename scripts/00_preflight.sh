#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)

for required_file in docker-compose.yml .env.example; do
  if [[ ! -f "$PROJECT_DIR/$required_file" ]]; then
    echo "ERROR: Missing required file: $PROJECT_DIR/$required_file" >&2
    exit 1
  fi
done

echo "Project directory: $PROJECT_DIR"
echo "Hostname: $(hostname)"
echo "User: $(whoami)"
echo "Date (UTC): $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo

echo "== Docker =="
if command -v docker >/dev/null 2>&1; then
  docker --version
else
  echo "Docker Engine: not installed"
fi

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  docker compose version
else
  echo "Docker Compose plugin: not installed"
fi
echo

echo "== Disk Layout =="
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS
echo
df -h
echo
findmnt -T /
if findmnt -T /data >/dev/null 2>&1; then
  findmnt -T /data
else
  echo "/data is not a dedicated mount yet."
fi
echo

root_source=$(findmnt -nro SOURCE -T /)
data_source=$(findmnt -nro SOURCE -T /data 2>/dev/null || true)
if [[ -z "$data_source" || "$data_source" == "$root_source" ]]; then
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
  echo "Suggestion: inspect and mount a dedicated data disk manually after reviewing a plan. No mkfs/parted/fdisk actions were performed."
else
  echo "No extra unmounted data disks were detected beyond the root device."
fi

echo
echo "Preflight checks completed."