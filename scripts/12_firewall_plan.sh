#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
ENV_FILE="$PROJECT_DIR/.env"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

as_root() {
  if [[ ${EUID} -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

remove_broad_ssh_rules() {
  local removed=0

  while as_root ufw --force delete allow OpenSSH >/dev/null 2>&1; do
    removed=1
  done

  while as_root ufw --force delete allow 22/tcp >/dev/null 2>&1; do
    removed=1
  done

  if [[ $removed -eq 1 ]]; then
    echo "Removed broad SSH allow rules; only the configured SSH_TRUSTED_CIDR remains."
  fi
}

detect_public_host() {
  if [[ -n "$PUBLIC_HOST" ]]; then
    printf '%s\n' "$PUBLIC_HOST"
    return 0
  fi

  if command -v curl >/dev/null 2>&1; then
    if detected_host=$(curl -4 --connect-timeout 5 -fsS ifconfig.me 2>/dev/null); then
      printf '%s\n' "$detected_host"
      return 0
    fi
  fi

  printf '%s\n' '<PUBLIC_SERVER_IP_OR_DNS>'
}

APPLY=0
PUBLIC_HOST="${PUBLIC_HOST:-}"
SSH_TRUSTED_CIDR="${SSH_TRUSTED_CIDR:-}"
TRUSTED_CIDR="${TRUSTED_CIDR:-}"

usage() {
  echo "Usage: $0 [--apply] [--public-host HOST] [--trusted-cidr CIDR] [--ssh-cidr CIDR]" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply)
      APPLY=1
      ;;
    --public-host)
      shift
      if [[ $# -eq 0 ]]; then
        usage
        exit 1
      fi
      PUBLIC_HOST="$1"
      ;;
    --trusted-cidr)
      shift
      if [[ $# -eq 0 ]]; then
        usage
        exit 1
      fi
      TRUSTED_CIDR="$1"
      ;;
    --ssh-cidr)
      shift
      if [[ $# -eq 0 ]]; then
        usage
        exit 1
      fi
      SSH_TRUSTED_CIDR="$1"
      ;;
    *)
      usage
      exit 1
      ;;
  esac
  shift
done

PUBLIC_HOST=$(detect_public_host)

cat <<EOF
Recommended firewall posture:
- Allow SSH only from your admin path.
- Keep 5432, 6379, 9000, and 9001 closed to the public Internet by default.
- If direct remote access is required, only allow a specific TRUSTED_CIDR.
- Prefer SSH tunnels for WSL CLI usage.

Current public host: $PUBLIC_HOST

Recommended Tencent Cloud / cloud security group inbound rules:
- TCP 22 from ${SSH_TRUSTED_CIDR:-<YOUR_ADMIN_SSH_CIDR_OR_ANY>}
- TCP 5432 from ${TRUSTED_CIDR:-<TRUSTED_CIDR>}
- TCP 6379 from ${TRUSTED_CIDR:-<TRUSTED_CIDR>}
- TCP 9000 from ${TRUSTED_CIDR:-<TRUSTED_CIDR>}
- TCP 9001 from ${TRUSTED_CIDR:-<TRUSTED_CIDR>} (optional, MinIO Console)

Suggested direct-public endpoints after allowlisting:
- PostgreSQL: ${PUBLIC_HOST}:5432
- MinIO S3 API: http://${PUBLIC_HOST}:9000
- MinIO Console: http://${PUBLIC_HOST}:9001
- Redis: ${PUBLIC_HOST}:6379

Suggested UFW commands:
${SSH_TRUSTED_CIDR:+- ufw allow from $SSH_TRUSTED_CIDR to any port 22 proto tcp}
${SSH_TRUSTED_CIDR:-- ufw allow OpenSSH}
- ufw allow from ${TRUSTED_CIDR:-<TRUSTED_CIDR>} to any port 5432 proto tcp
- ufw allow from ${TRUSTED_CIDR:-<TRUSTED_CIDR>} to any port 6379 proto tcp
- ufw allow from ${TRUSTED_CIDR:-<TRUSTED_CIDR>} to any port 9000 proto tcp
- ufw allow from ${TRUSTED_CIDR:-<TRUSTED_CIDR>} to any port 9001 proto tcp
- ufw enable
EOF

if [[ $APPLY -eq 0 ]]; then
  echo
  echo "Plan only. No firewall changes were applied."
  exit 0
fi

if [[ -z "$TRUSTED_CIDR" ]]; then
  echo "ERROR: TRUSTED_CIDR must be set before using --apply." >&2
  exit 1
fi

if ! command -v ufw >/dev/null 2>&1; then
  echo "ERROR: ufw is not installed. Install it first or apply the rules manually." >&2
  exit 1
fi

if [[ -n "$SSH_TRUSTED_CIDR" ]]; then
  as_root ufw allow from "$SSH_TRUSTED_CIDR" to any port 22 proto tcp
  remove_broad_ssh_rules
else
  as_root ufw allow OpenSSH
fi
for port in 5432 9000 9001 6379; do
  as_root ufw allow from "$TRUSTED_CIDR" to any port "$port"
done
as_root ufw --force enable
as_root ufw status verbose