#!/bin/bash

set -e

echo "=== [Server] Starting setup ==="

# ── 0. Install dependencies ──────────────────────────────────────────────────
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl

echo "=== [Server] Dependencies installed ==="

# ── 1. Install K3s in server mode ───────────────────────────────────────────
# Same as Part 1 but only one machine this time
# No worker, so no token sharing needed

curl -sfL https://get.k3s.io | \
    INSTALL_K3S_VERSION="v1.28.15+k3s1" \
    INSTALL_K3S_EXEC="server --flannel-iface=eth1 --node-ip=192.168.56.110" \
    sh -

echo "=== [Server] K3s installed ==="

# ── 2. Wait for K3s to be ready ─────────────────────────────────────────────
# We wait for the node to be Ready before applying manifests
# kubectl wait blocks until the condition is met or timeout is reached

echo "=== [Server] Waiting for K3s to be ready ==="

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# Wait up to 60 seconds for the node to be Ready
kubectl wait --for=condition=Ready node/akaddours \
    --timeout=60s

echo "=== [Server] K3s is ready ==="

# ── 3. Apply all manifests ───────────────────────────────────────────────────
# /vagrant/confs/ maps to p2/confs/ on your host
# kubectl apply -f on a directory applies ALL yaml files in it
# Order: app1, app2, app3 first (Services must exist before Ingress references them)

kubectl apply -f /vagrant/confs/app1.yaml
kubectl apply -f /vagrant/confs/app2.yaml
kubectl apply -f /vagrant/confs/app3.yaml
kubectl apply -f /vagrant/confs/ingress.yaml

echo "=== [Server] Manifests applied ==="

# ── 4. Fix kubectl permissions ───────────────────────────────────────────────
chmod 644 /etc/rancher/k3s/k3s.yaml
echo "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml" >> /home/vagrant/.bashrc

echo "=== [Server] Setup complete! ==="