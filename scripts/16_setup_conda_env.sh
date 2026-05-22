#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
ENV_FILE="$PROJECT_DIR/environment.yml"
CONDA_ROOT="${CONDA_ROOT:-$HOME/miniconda3}"
CONDA_ENV_NAME="${CONDA_ENV_NAME:-robot-dh}"
INSTALLER_URL="${MINICONDA_INSTALLER_URL:-https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh}"
INSTALLER_PATH="/tmp/robot-dh-miniconda.sh"

usage() {
  echo "Usage: $0 [--use-base]" >&2
}

USE_BASE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --use-base)
      USE_BASE=1
      ;;
    *)
      usage
      exit 1
      ;;
  esac
  shift
done

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE not found." >&2
  exit 1
fi

download_miniconda() {
  curl --retry 3 --retry-delay 2 --retry-connrefused -fsSL -o "$INSTALLER_PATH" "$INSTALLER_URL"
}

ensure_conda_installed() {
  if [[ -x "$CONDA_ROOT/bin/conda" ]]; then
    return 0
  fi

  download_miniconda
  bash "$INSTALLER_PATH" -b -p "$CONDA_ROOT"
  rm -f "$INSTALLER_PATH"
}

ensure_conda_initialized() {
  local conda_bin="$CONDA_ROOT/bin/conda"

  "$conda_bin" config --set auto_activate_base false >/dev/null
  "$conda_bin" init bash >/dev/null
}

update_environment() {
  local conda_bin="$CONDA_ROOT/bin/conda"

  if [[ $USE_BASE -eq 1 ]]; then
    "$conda_bin" env update -n base -f "$ENV_FILE" --prune
  else
    "$conda_bin" env update -n "$CONDA_ENV_NAME" -f "$ENV_FILE" --prune
  fi
}

print_next_steps() {
  cat <<EOF
Conda installed under: $CONDA_ROOT
Environment file: $ENV_FILE
Target environment: $(if [[ $USE_BASE -eq 1 ]]; then echo base; else echo "$CONDA_ENV_NAME"; fi)

Activation commands:
  source "$CONDA_ROOT/etc/profile.d/conda.sh"
  conda activate $(if [[ $USE_BASE -eq 1 ]]; then echo base; else echo "$CONDA_ENV_NAME"; fi)

Verification:
  python --version
  python -m pip --version
EOF
}

ensure_conda_installed
ensure_conda_initialized
update_environment
print_next_steps
