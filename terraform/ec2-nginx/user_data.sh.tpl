#!/bin/bash
set -euxo pipefail

dnf update -y
# nginx here is never started as a systemd service — the module runs inside
# the Docker stack instead, brought up by a later provisioner.
dnf install -y docker wget git rsync iptables

systemctl enable docker
systemctl start docker

usermod -aG docker ec2-user

# Docker Compose and Buildx aren't in AL2023's dnf repos, so install them
# as CLI plugins from Docker's official GitHub releases, system-wide so
# both root and ec2-user pick them up.
mkdir -p /usr/local/lib/docker/cli-plugins

curl -fsSL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-$(uname -m)" \
  -o /usr/local/lib/docker/cli-plugins/docker-compose
chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

# Buildx release assets are versioned in the filename (no stable
# "latest/download" alias like compose has), and use Go arch names
# (amd64) rather than uname -m (x86_64) — hardcoded here since this
# user_data is only ever rendered for the x86_64 AMI looked up in ec2.tf.
buildx_url=$(curl -fsSL https://api.github.com/repos/docker/buildx/releases/latest \
  | grep '"browser_download_url"' \
  | grep 'linux-amd64"' \
  | head -n1 \
  | cut -d '"' -f 4)
curl -fsSL "$buildx_url" -o /usr/local/lib/docker/cli-plugins/docker-buildx
chmod +x /usr/local/lib/docker/cli-plugins/docker-buildx

# The app itself is NOT started here — the repo doesn't exist yet at this
# point in boot; it's rsync'd in and started by later provisioners in ec2.tf.