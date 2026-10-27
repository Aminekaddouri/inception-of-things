#!/bin/bash

# Exit on any error
set -e

CHART_VERSION="9.11.8"
GITLAB_HOST="gitlab.local"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Bonus Part — GitLab + Argo CD Setup"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# STEP 0 — System locale fix + base dependencies
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export DEBIAN_FRONTEND=noninteractive

apt-get update -qq
apt-get install -y -qq curl wget git jq apt-transport-https \
    ca-certificates gnupg lsb-release

echo "=== [Step 0] Base dependencies installed ==="

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# STEP 1 — Install Docker
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

curl -fsSL https://get.docker.com | sh
usermod -aG docker vagrant
systemctl enable docker
systemctl start docker

echo "=== [Step 1] Docker installed ==="

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# STEP 2 — Install kubectl
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

curl -LO "https://dl.k8s.io/release/v1.28.15/bin/linux/amd64/kubectl"
chmod +x kubectl && mv kubectl /usr/local/bin/kubectl

echo "=== [Step 2] kubectl installed ==="

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# STEP 3 — Install K3d
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash

echo "=== [Step 3] K3d installed ==="

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# STEP 4 — Install Helm
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

echo "=== [Step 4] Helm installed ==="

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# STEP 5 — Create K3d cluster
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Port 80  → GitLab web UI + Argo CD (via Traefik Ingress)
# Port 8888→ wil-playground app (NodePort 30888)

k3d cluster create iot \
    --servers 1 \
    --port "80:80@loadbalancer" \
    --port "8888:30888@loadbalancer" \
    --wait

# Copy kubeconfig for vagrant user
mkdir -p /home/vagrant/.kube
cp /root/.kube/config /home/vagrant/.kube/config
chown vagrant:vagrant /home/vagrant/.kube/config

echo "=== [Step 5] K3d cluster created ==="

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# STEP 6 — Create namespaces
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

kubectl create namespace gitlab
kubectl create namespace argocd
kubectl create namespace dev

echo "=== [Step 6] Namespaces created ==="

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# STEP 7 — Install GitLab via Helm
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# FIX 1: filename was gitlab_values.yaml (underscore) — actual file uses a
#         hyphen: gitlab-values.yaml

helm repo add gitlab https://charts.gitlab.io/ --force-update
helm repo update

################################################
helm upgrade --install gitlab gitlab/gitlab \
  --version "${CHART_VERSION}" \
  --namespace gitlab \
  --timeout 900s \
  -f "/vagrant/confs/gitlab-values.yaml"

echo "=== [Step 7] GitLab chart installed — waiting for pods (10-15 min) ==="

kubectl wait --for=condition=available deployment --all -n gitlab --timeout=1800s

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# STEP 8 — Resolve gitlab.local on the VM
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# The K3d load balancer binds to 0.0.0.0 on the VM, so 127.0.0.1 is fine
# for VM-local curl/git calls.

if ! grep -q " ${GITLAB_HOST}" /etc/hosts; then
  echo "127.0.0.1 ${GITLAB_HOST}" >> /etc/hosts
fi

until curl -sf "http://${GITLAB_HOST}/users/sign_in" > /dev/null; do
  echo "  Waiting for http://${GITLAB_HOST} ..."
  sleep 10
done

echo "=== GitLab is up: http://${GITLAB_HOST} ==="

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# STEP 9 — Configure GitLab (token + project)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

echo "=== [Step 9] Configuring GitLab ==="

GITLAB_URL="http://${GITLAB_HOST}"

GITLAB_PASSWORD=$(kubectl get secret gitlab-gitlab-initial-root-password \
    -n gitlab \
    -o jsonpath='{.data.password}' | base64 -d)

echo "  Root password retrieved"

# Wait for the Rails stack to accept HTTP (beyond just TCP)
until curl -sf "${GITLAB_URL}/users/sign_in" | grep -q "GitLab" 2>/dev/null; do
    echo "  ...waiting 10s for GitLab HTTP"
    sleep 10
done
echo "  GitLab HTTP is responding"

# Create a personal access token via the Rails runner (most reliable method)
TOOLBOX_POD=$(kubectl get pods -n gitlab \
    --no-headers | grep toolbox | awk '{print $1}')
echo "  Using toolbox pod: $TOOLBOX_POD"

GITLAB_TOKEN=$(kubectl exec -n gitlab "$TOOLBOX_POD" -- \
    gitlab-rails runner "
token = User.find(1).personal_access_tokens.create(
  name: 'argo-token',
  scopes: ['api', 'read_repository', 'write_repository'],
  expires_at: 365.days.from_now
)
puts token.token
" 2>/dev/null | tail -1)

echo "  Personal access token created: $GITLAB_TOKEN"

# Create the 'iot' project
curl -s --request POST \
    "${GITLAB_URL}/api/v4/projects" \
    --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
    --header "Content-Type: application/json" \
    --data '{"name":"iot","visibility":"public","initialize_with_readme":false}' \
    > /dev/null

echo "  Project 'iot' created"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# STEP 10 — Push deployment.yaml to local GitLab
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# FIX 3: was pushing to localhost:9090 but port-forward was commented out.
#         We now push to http://gitlab.local (port 80 via K3d load balancer).

echo "=== [Step 10] Pushing manifests to local GitLab ==="

git config --global user.email "root@gitlab.local"
git config --global user.name "root"
git config --global init.defaultBranch main

cd /tmp
rm -rf iot-repo && mkdir iot-repo && cd iot-repo

git init
mkdir -p confs
cp /vagrant/confs/deployment.yaml confs/
git add .
git commit -m "initial: add deployment manifest"

# Push directly to gitlab.local (reachable from the VM via /etc/hosts + K3d LB)
git remote add origin \
    "http://root:${GITLAB_TOKEN}@${GITLAB_HOST}/root/iot.git"

git push -u origin main

cd /

chown -R vagrant:vagrant /tmp/iot-repo

sudo -u vagrant git config --global user.email "root@gitlab.local"
sudo -u vagrant git config --global user.name "root"

echo "=== [Step 10] Manifests pushed to local GitLab ==="

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# STEP 11 — Install Argo CD
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

kubectl apply -n argocd \
    -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml \
    || true

echo "=== [Step 11] Argo CD manifests applied ==="

kubectl wait --for=condition=available deployment/argocd-server \
    -n argocd --timeout=300s

echo "=== [Step 11] Argo CD ready ==="

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# STEP 12 — Register GitLab repo with Argo CD
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# FIX 4: git-http is proxied by gitlab-workhorse, NOT webservice.
#         Use the workhorse service on port 8181 for internal cluster cloning.
# FIX 7: K3d cluster nodes can't read the VM's /etc/hosts, so we must use
#         the in-cluster service DNS name — not "gitlab.local".

GITLAB_INTERNAL_URL="http://gitlab-webservice-default.gitlab.svc.cluster.local:8181"


kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: gitlab-repo-secret
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
type: Opaque
stringData:
  type: git
  url: ${GITLAB_INTERNAL_URL}/root/iot.git
  username: root
  password: ${GITLAB_TOKEN}
EOF

echo "=== [Step 12] GitLab repo registered with Argo CD ==="

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# STEP 13 — Create Argo CD Application
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: wil-playground
  namespace: argocd
spec:
  project: default

  source:
    repoURL: ${GITLAB_INTERNAL_URL}/root/iot.git
    targetRevision: HEAD
    path: confs

  destination:
    server: https://kubernetes.default.svc
    namespace: dev

  syncPolicy:
    automated:
      selfHeal: true
      prune: true
    syncOptions:
      - CreateNamespace=true
EOF

echo "=== [Step 13] Argo CD Application created ==="

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# STEP 14 — Wait for app to deploy
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

echo "=== [Step 14] Waiting for Argo CD to sync and app to deploy ==="

until kubectl get deployment wil-playground -n dev &>/dev/null; do
    echo "  waiting for Argo CD to sync..."
    sleep 5
done

kubectl wait --for=condition=available deployment/wil-playground \
    -n dev --timeout=120s

echo "=== [Step 14] App is running ==="

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# STEP 15 — Print summary
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Installation complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo " GitLab UI:       http://gitlab.local  (add 192.168.X.X gitlab.local to your HOST /etc/hosts)"
echo " GitLab user:     root"
echo " GitLab password: ${GITLAB_PASSWORD}"
echo " GitLab repo:     http://gitlab.local/root/iot"
echo ""
echo " App URL (from VM):   curl http://localhost:8888/"
echo ""
echo " Namespaces:"
kubectl get namespaces
echo ""
echo " GitLab pods:"
kubectl get pods -n gitlab
echo ""
echo " Argo CD pods:"
kubectl get pods -n argocd
echo ""
echo " App pod:"
kubectl get pods -n dev
echo ""
echo " App response:"
curl -s http://localhost:8888/ || echo "(app not reachable yet — wait a moment and retry)"
echo ""
echo ""
echo " To switch to v2 — run inside the VM:"
echo "   cd /tmp/iot-repo"
echo "   sed -i 's/playground:v1/playground:v2/' confs/deployment.yaml"
echo "   git add . && git commit -m 'update to v2' && git push"
echo "   # Argo CD auto-syncs every 3 min, then:"
echo "   curl http://localhost:8888/"