#!/bin/bash

# Exit on any error
set -e

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Bonus Part — GitLab + Argo CD Setup"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# STEP 0 — System locale fix + base dependencies
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Fix the locale warnings we saw in Part 3
# These warnings don't break things but are noisy

export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export DEBIAN_FRONTEND=noninteractive

apt-get update -qq
apt-get install -y -qq \
    curl \
    wget \
    git \
    jq \
    apt-transport-https \
    ca-certificates \
    gnupg \
    lsb-release

# jq = command-line JSON parser
# We need it to parse GitLab API responses
# git = to push deployment.yaml to local GitLab

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
chmod +x kubectl
mv kubectl /usr/local/bin/kubectl

echo "=== [Step 2] kubectl installed ==="

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# STEP 3 — Install K3d
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash

echo "=== [Step 3] K3d installed ==="

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# STEP 4 — Install Helm
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Helm is the package manager for Kubernetes
# We need it to install GitLab (too complex to install manually)

curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

echo "=== [Step 4] Helm installed ==="

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# STEP 5 — Create K3d cluster
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Two port mappings this time:
# 8888:30000 → our app (same as Part 3)
# 8181:32080 → GitLab web UI

k3d cluster create iot \
    --port "8888:30000@loadbalancer" \
    --port "8181:32080@loadbalancer" \
    --wait

# Copy kubeconfig for vagrant user
mkdir -p /home/vagrant/.kube
cp /root/.kube/config /home/vagrant/.kube/config
chown vagrant:vagrant /home/vagrant/.kube/config

echo "=== [Step 5] K3d cluster created ==="

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# STEP 6 — Create namespaces
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Three namespaces required by the subject:
# - gitlab: GitLab platform
# - argocd: Argo CD
# - dev: our application

kubectl create namespace gitlab
kubectl create namespace argocd
kubectl create namespace dev

echo "=== [Step 6] Namespaces created ==="

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# STEP 7 — Install GitLab via Helm
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Add the official GitLab Helm chart repository
# Then install using our minimal values file

helm repo add gitlab https://charts.gitlab.io
helm repo update

echo "=== [Step 7a] Helm repo added ==="

# Install GitLab
# --timeout 900s = wait up to 15 minutes (GitLab takes a while)
# --values = use our custom minimal configuration
# --set = override specific values inline

helm install gitlab gitlab/gitlab \
    --namespace gitlab \
    --timeout 900s \
    --values /vagrant/confs/gitlab-values.yaml \
    --set global.hosts.externalIP=127.0.0.1 \
    --set gitlab.webservice.service.type=NodePort \
    --set gitlab.webservice.service.nodePort=32080

echo "=== [Step 7b] GitLab Helm install complete ==="

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# STEP 8 — Wait for GitLab to be ready
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# GitLab has multiple components that must all be ready
# We wait for the webservice (main component) last

echo "=== [Step 8] Waiting for GitLab to be ready (this takes 5-10 minutes) ==="

# Wait for database migrations to complete first
kubectl wait --for=condition=complete job/gitlab-migrations \
    -n gitlab --timeout=600s

# Wait for the webservice to be available
kubectl wait --for=condition=available deployment/gitlab-webservice-default \
    -n gitlab --timeout=600s

echo "=== [Step 8] GitLab is ready ==="

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# STEP 9 — Configure GitLab
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# GitLab generates a random initial root password
# We retrieve it, then use the API to:
# 1. Create a personal access token
# 2. Create a project (repository)
# 3. Push our deployment.yaml to it

echo "=== [Step 9] Configuring GitLab ==="

# Get the initial root password
# GitLab stores it in a Kubernetes Secret automatically
GITLAB_PASSWORD=$(kubectl get secret gitlab-gitlab-initial-root-password \
    -n gitlab \
    -o jsonpath='{.data.password}' | base64 -d)

echo "  Root password retrieved"

# GitLab URL — accessible from inside the VM via port-forward
# or via the NodePort we configured
GITLAB_URL="http://localhost:8181"

# Wait for GitLab HTTP to actually respond
# (the deployment being "available" doesn't mean HTTP is ready yet)
echo "  Waiting for GitLab HTTP to respond..."
until curl -s --max-time 5 "$GITLAB_URL/users/sign_in" | \
    grep -q "GitLab" 2>/dev/null; do
    echo "  ...not ready yet, waiting 10s"
    sleep 10
done

echo "  GitLab HTTP is responding"

# Create a Personal Access Token via the API
# This token lets Argo CD authenticate with GitLab
GITLAB_TOKEN=$(curl -s --request POST \
    "$GITLAB_URL/api/v4/users/1/personal_access_tokens" \
    --header "Content-Type: application/json" \
    --data '{
        "name": "argo-token",
        "scopes": ["api", "read_repository", "write_repository"],
        "user_id": 1
    }' \
    --user "root:$GITLAB_PASSWORD" \
    | jq -r '.token')

echo "  Personal access token created: $GITLAB_TOKEN"

# Create a project (repository) named 'iot'
curl -s --request POST \
    "$GITLAB_URL/api/v4/projects" \
    --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
    --header "Content-Type: application/json" \
    --data '{
        "name": "iot",
        "visibility": "public",
        "initialize_with_readme": false
    }' > /dev/null

echo "  Project 'iot' created"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# STEP 10 — Push deployment.yaml to local GitLab
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Argo CD needs the manifests to be in the GitLab repo
# We push the same deployment.yaml we used in Part 3

echo "=== [Step 10] Pushing manifests to local GitLab ==="

git config --global user.email "root@gitlab.local"
git config --global user.name "root"
git config --global init.defaultBranch main

# Create a temp directory, initialize a git repo
# copy our deployment.yaml and push to local GitLab
cd /tmp
rm -rf iot-repo
mkdir iot-repo
cd iot-repo

git init
mkdir -p confs
cp /vagrant/confs/deployment.yaml confs/
git add .
git commit -m "initial: add deployment manifest"

# Push using root credentials embedded in the URL
# http://root:PASSWORD@localhost:8181/root/iot.git
git remote add origin \
    "http://root:$GITLAB_TOKEN@localhost:8181/root/iot.git"

git push -u origin main

cd /
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

echo "=== [Step 11] Argo CD is ready ==="

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# STEP 12 — Register GitLab repo with Argo CD
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Argo CD needs credentials to clone from our local GitLab
# We create a Kubernetes Secret with the repo URL and token
# Argo CD watches for Secrets with this specific label

# The GitLab URL from INSIDE the cluster (using internal DNS)
# This is different from localhost:8181 which only works from the VM host
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
# Same as Part 3 but pointing to LOCAL GitLab instead of GitHub

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
    path: confs             # folder in our local repo

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

echo "=== [Step 14] Waiting for app to deploy ==="

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
echo " GitLab UI:       http://localhost:8181"
echo " GitLab user:     root"
echo " GitLab password: $GITLAB_PASSWORD"
echo " GitLab repo:     http://localhost:8181/root/iot"
echo ""
echo " App URL:         curl http://localhost:8888/"
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
curl -s http://localhost:8888/
echo ""
echo ""
echo " To switch app version:"
echo "   1. Edit /tmp/iot-repo/confs/deployment.yaml"
echo "   2. Change v1 to v2 (or v2 to v1)"
echo "   3. Run:"
echo "      cd /tmp/iot-repo"
echo "      git add . && git commit -m 'update version'"
echo "      git push"
echo "   4. Wait ~3 minutes or trigger sync:"
echo "      kubectl patch app wil-playground -n argocd \\"
echo "        --type merge -p '{\"operation\":{\"initiatedBy\":{\"username\":\"admin\"},\"sync\":{}}}'"