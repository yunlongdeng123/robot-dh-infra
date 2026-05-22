#!/usr/bin/env bash
set -euo pipefail

PIP_CONF_DIR="$HOME/.pip"
PIP_CONF_FILE="$PIP_CONF_DIR/pip.conf"
MC_TMP="/tmp/robot-dh-mc"

python_bin() {
  if [[ -n "${CONDA_PREFIX:-}" && -x "$CONDA_PREFIX/bin/python" ]]; then
    printf '%s\n' "$CONDA_PREFIX/bin/python"
  else
    printf '%s\n' python3
  fi
}

as_root() {
  if [[ ${EUID} -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

detect_pypi_mirror() {
  local candidates=(
    "mirrors.tencentyun.com http://mirrors.tencentyun.com/pypi/simple"
    "mirrors.tencent.com http://mirrors.tencent.com/pypi/simple"
  )

  local entry host url
  for entry in "${candidates[@]}"; do
    host=${entry%% *}
    url=${entry#* }
    if curl -fsSI --max-time 5 "$url" >/dev/null 2>&1; then
      printf '%s %s\n' "$host" "$url"
      return 0
    fi
  done

  echo "ERROR: Could not reach Tencent Cloud PyPI mirrors." >&2
  exit 1
}

append_if_missing() {
  local file_path="$1"
  local line="$2"

  touch "$file_path"
  if ! grep -Fxq "$line" "$file_path"; then
    printf '%s\n' "$line" >> "$file_path"
  fi
}

remove_exact_line() {
  local file_path="$1"
  local line="$2"

  touch "$file_path"
  grep -Fxv "$line" "$file_path" > "$file_path.tmp.robot-dh"
  mv "$file_path.tmp.robot-dh" "$file_path"
}

pip_install() {
  local py_bin
  py_bin=$(python_bin)

  if [[ -n "${CONDA_PREFIX:-}" && -x "$CONDA_PREFIX/bin/python" ]]; then
    "$py_bin" -m pip install "$@"
  else
    "$py_bin" -m pip install --break-system-packages "$@"
  fi
}

link_user_local_script() {
  local script_name="$1"
  local source_path="$HOME/.local/bin/$script_name"

  if [[ -x "$source_path" ]]; then
    as_root ln -sf "$source_path" "/usr/local/bin/$script_name"
  fi
}

read -r PIP_TRUSTED_HOST PIP_INDEX_URL < <(detect_pypi_mirror)

mkdir -p "$PIP_CONF_DIR"
cat > "$PIP_CONF_FILE" <<EOF
[global]
index-url = $PIP_INDEX_URL
trusted-host = $PIP_TRUSTED_HOST
timeout = 120
EOF

as_root apt-get update
as_root apt-get install -y \
  git \
  git-lfs \
  aria2 \
  unzip \
  jq \
  rsync \
  python3-pip \
  python3-venv \
  ca-certificates \
  curl

git lfs install --skip-repo

pip_install --upgrade pip \
  --index-url "$PIP_INDEX_URL" \
  --trusted-host "$PIP_TRUSTED_HOST"

pip_install --upgrade \
  huggingface_hub \
  hf_transfer \
  h5py \
  openxlab \
  boto3 \
  pandas \
  pyarrow \
  tqdm \
  --index-url "$PIP_INDEX_URL" \
  --trusted-host "$PIP_TRUSTED_HOST"


link_user_local_script openxlab
link_user_local_script hf
link_user_local_script huggingface-cli

if ! command -v mc >/dev/null 2>&1; then
  curl --retry 3 --retry-delay 2 --retry-connrefused -fsSL -o "$MC_TMP" https://dl.min.io/client/mc/release/linux-amd64/mc
  as_root install -m 0755 "$MC_TMP" /usr/local/bin/mc
  rm -f "$MC_TMP"
fi

append_if_missing "$HOME/.bashrc" 'export PATH="$HOME/.local/bin:$PATH"'
append_if_missing "$HOME/.bashrc" "export HF_HOME=/data/robot-dh/cache/huggingface"
remove_exact_line "$HOME/.bashrc" "export HF_HUB_ENABLE_HF_TRANSFER=1"
append_if_missing "$HOME/.bashrc" "export HF_XET_HIGH_PERFORMANCE=1"
append_if_missing "$HOME/.bashrc" "export OPENXLAB_CACHE_DIR=/data/robot-dh/cache/openxlab"

export PATH="$HOME/.local/bin:$PATH"
export HF_HOME=/data/robot-dh/cache/huggingface
unset HF_HUB_ENABLE_HF_TRANSFER
export HF_XET_HIGH_PERFORMANCE=1
export OPENXLAB_CACHE_DIR=/data/robot-dh/cache/openxlab

echo "Configured pip to use Tencent Cloud mirror: $PIP_INDEX_URL"
echo "Installed git-lfs, aria2, jq, rsync, python tooling, and MinIO mc."
echo "Added HF_HOME, HF_XET_HIGH_PERFORMANCE, and OPENXLAB_CACHE_DIR to ~/.bashrc"
