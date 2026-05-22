#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
TEMPLATE_FILE="$PROJECT_DIR/client/wsl-open-tunnels.sh"
SSH_HOST=${SSH_HOST:-robot-dh-tencent}
SSH_USER=${SSH_USER:-ubuntu}
SSH_PORT=${SSH_PORT:-22}
FORCE=0

usage() {
  echo "Usage: $0 [--force]" >&2
}

if [[ $# -gt 1 ]]; then
  usage
  exit 1
fi

if [[ $# -eq 1 ]]; then
  if [[ "$1" != "--force" ]]; then
    usage
    exit 1
  fi
  FORCE=1
fi

template_content=$(cat <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

SSH_HOST="${SSH_HOST:-robot-dh-tencent}"
SSH_USER="${SSH_USER:-ubuntu}"
SSH_PORT="${SSH_PORT:-22}"
SSH_IDENTITY_FILE="${SSH_IDENTITY_FILE:-}"

ssh_args=(
  -NT
  -o ExitOnForwardFailure=yes
  -o ServerAliveInterval=30
  -o ServerAliveCountMax=3
  -p "$SSH_PORT"
  -L 15432:127.0.0.1:5432
  -L 19000:127.0.0.1:9000
  -L 19001:127.0.0.1:9001
  -L 16379:127.0.0.1:6379
)

if [[ -n "$SSH_IDENTITY_FILE" ]]; then
  ssh_args+=( -i "$SSH_IDENTITY_FILE" )
fi

exec ssh "${ssh_args[@]}" "${SSH_USER}@${SSH_HOST}"
EOF
)

if [[ -f "$TEMPLATE_FILE" && $FORCE -ne 1 ]]; then
  existing_content=$(cat "$TEMPLATE_FILE")
  if [[ "$existing_content" == "$template_content" ]]; then
    echo "Template already up to date at $TEMPLATE_FILE"
  else
    echo "WARNING: $TEMPLATE_FILE already exists and differs; preserving it. Re-run with --force to overwrite." >&2
  fi
else
  printf '%s\n' "$template_content" > "$TEMPLATE_FILE"
  chmod +x "$TEMPLATE_FILE"
  echo "Template written to $TEMPLATE_FILE"
fi

cat <<EOF
SSH_PORT=${SSH_PORT} \
ssh -NT \
  -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=30 \
  -o ServerAliveCountMax=3 \
  -p ${SSH_PORT:-22} \
  -L 15432:127.0.0.1:5432 \
  -L 19000:127.0.0.1:9000 \
  -L 19001:127.0.0.1:9001 \
  -L 16379:127.0.0.1:6379 \
  ${SSH_USER}@${SSH_HOST}
EOF