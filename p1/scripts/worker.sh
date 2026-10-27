#!/bin/bash

set -e

echo "=== [Worker] Starting K3s agent setup ==="

# ── 0. Install dependencies ─────────────────────────────────────────────────
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl

echo "=== [Worker] Dependencies installed ==="

# ── 1. Read the token the server wrote ─────────────────────────────────────

# The server script wrote the token to /vagrant/node-token.
# /vagrant is the same shared folder — we just read it from here.

TOKEN=$(cat /vagrant/node-token)

echo "=== [Worker] Token retrieved, joining cluster ==="

# ── 2. Install K3s in agent mode ───────────────────────────────────────────

# K3S_URL   → tells the installer "be an agent, connect to this server"
# K3S_TOKEN → the secret the server generated; proves we're allowed to join
#
# INSTALL_K3S_EXEC="agent --flannel-iface=eth1 --node-ip=192.168.56.111"
#   Same reasoning as the server: use eth1 (our private network interface)
#   not eth0 (the NAT interface), and advertise our correct IP.

curl -sfL https://get.k3s.io | \
    INSTALL_K3S_VERSION="v1.28.15+k3s1" \
    K3S_URL=https://192.168.56.110:6443 \
    K3S_TOKEN=$TOKEN \
    INSTALL_K3S_EXEC="agent --flannel-iface=eth1 --node-ip=192.168.56.111" \
    sh -

echo "=== [Worker] K3s agent installed and joined cluster ==="