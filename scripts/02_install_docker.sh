#!/usr/bin/env bash
set -euo pipefail

as_root() {
  if [[ ${EUID} -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

docker_present=0
compose_present=0

if command -v docker >/dev/null 2>&1; then
  docker_present=1
  docker --version
else
  echo "Docker Engine is not installed."
fi

if [[ $docker_present -eq 1 ]] && docker compose version >/dev/null 2>&1; then
  compose_present=1
  docker compose version
else
  echo "Docker Compose plugin is not installed."
fi

if [[ $docker_present -eq 0 || $compose_present -eq 0 ]]; then
  echo "Installing Docker Engine and docker compose plugin from the official Ubuntu repository..."
  as_root apt-get update
  as_root apt-get install -y ca-certificates curl
  as_root install -m 0755 -d /etc/apt/keyrings
  as_root curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  as_root chmod a+r /etc/apt/keyrings/docker.asc

  arch=$(dpkg --print-architecture)
  codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
  echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${codename} stable" | as_root tee /etc/apt/sources.list.d/docker.list >/dev/null

  as_root apt-get update
  as_root apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  as_root systemctl enable --now docker
else
  echo "Docker Engine and docker compose plugin already exist; skipping package installation."
fi

if ! getent group docker >/dev/null 2>&1; then
  as_root groupadd docker
fi

if id -nG "$USER" | grep -qw docker; then
  echo "User $USER is already in the docker group."
else
  as_root usermod -aG docker "$USER"
  echo "Added $USER to the docker group."
fi

docker --version
docker compose version

echo "Docker installation step completed. You may need to run 'newgrp docker' or re-login before using docker without sudo."