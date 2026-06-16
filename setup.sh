#!/usr/bin/env bash

# Exit immediately if a command exits with a non-zero status
set -e

echo "🚀 Setting up the Redis Cluster Testing Environment..."

# 1. Fix executable permissions for the CLI tool
echo "🔧 Fixing permissions for redis-tool..."
chmod +x redis-tool

# 2. Fix SSH private key permissions
# Git often resets these to 644 on clone, which causes SSH to throw "Permission denied"
if [ -f "infra/id_rsa" ]; then
    echo "🔑 Fixing permissions for Ansible SSH private key..."
    chmod 600 infra/id_rsa
fi

# 3. Inform the user
echo ""
echo "✅ Environment is configured!"
echo ""
echo "To bring up the infrastructure, run:"
echo "    cd infra"
echo "    docker compose up -d    (or podman-compose up -d)"
echo ""
echo "Then, to provision the cluster, run:"
echo "    ./redis-tool provision --version 7.0.15 --masters 3 --replicas-per-master 1"
