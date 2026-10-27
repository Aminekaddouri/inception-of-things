#!/bin/bash

# -e = exit immediately if any command fails
# This prevents silent failures during provisioning and ensures that errors are caught early.
set -e

echo "=== [Server] Starting K3s server setup ==="

# ── 0. Install dependencies ─────────────────────────────────────────────────
# The base Debian box is minimal — curl isn't included by default.
# -qq = quiet mode, DEBIAN_FRONTEND=noninteractive = no prompts

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl

echo "=== [Server] Dependencies installed ==="

# ── 1. Install K3s in server mode ──────────────────────────────────────────

# INSTALL_K3S_EXEC tells the installer extra flags to pass to k3s server
# --flannel-iface=eth1
#   K3s uses flannel for pod networking. By default it picks eth0, which is
#   Vagrant's NAT interface (10.0.2.15 — same on ALL VMs, useless for
#   inter-node communication). eth1 is the private network interface with
#   our real IPs (192.168.56.x), so we force flannel to use that.
#
# --node-ip=192.168.56.110
#   Explicitly tells K3s to advertise this IP to the cluster.
#   Without this, the node might register with the wrong IP.

echo "=== [Server] Using network interface: $IFACE ==="

curl -sfL https://get.k3s.io | \
    INSTALL_K3S_VERSION="v1.28.15+k3s1" \
    INSTALL_K3S_EXEC="server --flannel-iface=eth1 --node-ip=192.168.56.110" \
    sh -

echo "=== [Server] K3s installed, waiting for it to be ready ==="

# ── 2. Wait for K3s to be fully ready ──────────────────────────────────────

# K3s starts as a systemd service but takes a few seconds to initialize.
# We wait until the node-token file exists — that means the server is up
# and has generated credentials for agents to use.

while [ ! -f /var/lib/rancher/k3s/server/node-token ]; do
    echo "  waiting for node-token..."
    sleep 2
done

echo "=== [Server] Node token is ready ==="

# ── 3. Share the token via the /vagrant shared folder ──────────────────────

# /vagrant inside the VM = the folder on your HOST where Vagrantfile is.
# Both VMs share this same folder, so writing here makes it readable
# by the worker VM's provisioning script too.

cp /var/lib/rancher/k3s/server/node-token /vagrant/node-token

echo "=== [Server] Token copied to /vagrant/node-token ==="

# ── 4. Fix kubectl permissions ─────────────────────────────────────────────

# K3s writes its kubeconfig (the file kubectl uses to know where/how to
# connect) to /etc/rancher/k3s/k3s.yaml, but it's only readable by root.
# We make it world-readable so the vagrant user can run kubectl without sudo.

chmod 644 /etc/rancher/k3s/k3s.yaml

# Also set KUBECONFIG in the vagrant user's shell so kubectl works
# immediately when you do "vagrant ssh akaddourS"

echo "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml" >> /home/vagrant/.bashrc

echo "=== [Server] Setup complete! ==="