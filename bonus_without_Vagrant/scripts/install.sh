#!/bin/bash

# Exit on any error
set -e

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Bonus Part — GitLab + Argo CD Setup"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# CONFIG — paths and versions
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# Script's own directory — confs/ lives next to scripts/
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFS_DIR="$(dirname "$SCRIPT_DIR")/confs"

# The real user who ran sudo (so we set up kubeconfig for them, not root)
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

echo "  Script dir : $SCRIPT_DIR"
echo "  Confs dir  : $CONFS_DIR"
echo "  Real user  : $REAL_USER ($REAL_HOME)"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# STEP 0 — Locale + base dependencies
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export DEBIAN_FRONTEND=noninteractive

apt-get update -qq
apt-get install -y -qq curl wget git jq apt-transport-https \
    ca-certificates gnupg lsb-release openssl

echo "=== [Step 0] Base dependencies installed ==="

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# STEP 1 — Docker (skip if already installed)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

if command -v docker &>/dev/null; then
    echo "=== [Step 1] Docker already installed ($(docker --version)) — skipping ==="
else
    curl -fsSL https://get.docker.com | sh
    echo "=== [Step 1] Docker installed ==="
fi

usermod -aG docker "$REAL_USER" 2>/dev/null || true
systemctl enable docker --quiet
systemctl start docker

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# STEP 2 — kubectl (skip if already installed)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

if command -v kubectl &>/dev/null; then
    echo "=== [Step 2] kubectl already installed — skipping ==="
else
    curl -LO "https://dl.k8s.io/release/v1.28.15/bin/linux/amd64/kubectl"
    chmod +x kubectl && mv kubectl /usr/local/bin/kubectl
    echo "=== [Step 2] kubectl installed ==="
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# STEP 3 — K3d (skip if already installed)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

if command -v k3d &>/dev/null; then
    echo "=== [Step 3] K3d already installed ($(k3d version | head -1)) — skipping ==="
else
    curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
    echo "=== [Step 3] K3d installed ==="
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# STEP 4 — Helm (skip if already installed)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

if command -v helm &>/dev/null; then
    echo "=== [Step 4] Helm already installed ($(helm version --short)) — skipping ==="
else
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    echo "=== [Step 4] Helm installed ==="
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# STEP 5 — K3d cluster (recreate if exists)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

if k3d cluster list 2>/dev/null | grep -q "^iot"; then
    echo "  K3d cluster 'iot' already exists — deleting and recreating..."
    k3d cluster delete iot
fi

k3d cluster create iot \
    --port "8888:30000@loadbalancer" \
    --port "8181:32080@loadbalancer" \
    --wait

mkdir -p "$REAL_HOME/.kube"
cp /root/.kube/config "$REAL_HOME/.kube/config"
chown "$REAL_USER:$REAL_USER" "$REAL_HOME/.kube/config"

echo "=== [Step 5] K3d cluster created ==="

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# STEP 6 — Namespaces (idempotent via dry-run)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

kubectl create namespace gitlab --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace dev    --dry-run=client -o yaml | kubectl apply -f -

echo "=== [Step 6] Namespaces ready ==="

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# STEP 7 — PostgreSQL, Redis, GitLab
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

helm repo add gitlab https://charts.gitlab.io --force-update
helm repo update
echo "=== [Step 7a] Helm repo ready ==="

# Re-use existing passwords on re-runs so they match the existing DB data
if kubectl get secret gitlab-postgresql-password -n gitlab &>/dev/null; then
    echo "  PostgreSQL secret exists — reading existing password"
    PG_PASSWORD=$(kubectl get secret gitlab-postgresql-password -n gitlab \
        -o jsonpath='{.data.postgresql-password}' | base64 -d)
else
    PG_PASSWORD=$(openssl rand -base64 16)
fi

if kubectl get secret gitlab-redis-secret -n gitlab &>/dev/null; then
    echo "  Redis secret exists — reading existing password"
    REDIS_PASSWORD=$(kubectl get secret gitlab-redis-secret -n gitlab \
        -o jsonpath='{.data.redis-password}' | base64 -d)
else
    REDIS_PASSWORD=$(openssl rand -base64 16)
fi

# kubectl apply is idempotent — safe to re-run
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: gitlab-postgresql-password
  namespace: gitlab
type: Opaque
stringData:
  postgresql-password: ${PG_PASSWORD}
  postgresql-postgres-password: ${PG_PASSWORD}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-pvc
  namespace: gitlab
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: local-path
  resources:
    requests:
      storage: 2Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: gitlab-postgresql
  namespace: gitlab
spec:
  replicas: 1
  selector:
    matchLabels:
      app: gitlab-postgresql
  template:
    metadata:
      labels:
        app: gitlab-postgresql
    spec:
      containers:
        - name: postgresql
          image: postgres:17
          args:
            - "postgres"
            - "-c"
            - "max_locks_per_transaction=256"
            - "-c"
            - "shared_buffers=256MB"
            - "-c"
            - "max_connections=100"
          env:
            - name: POSTGRES_USER
              value: gitlab
            - name: POSTGRES_DB
              value: gitlabhq_production
            - name: POSTGRES_PASSWORD
              value: ${PG_PASSWORD}
            - name: PGDATA
              value: /var/lib/postgresql/data/pgdata
          ports:
            - containerPort: 5432
          volumeMounts:
            - name: data
              mountPath: /var/lib/postgresql/data
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: postgres-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: gitlab-postgresql
  namespace: gitlab
spec:
  selector:
    app: gitlab-postgresql
  ports:
    - port: 5432
      targetPort: 5432
EOF
echo "=== [Step 7b] PostgreSQL deployed ==="

kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: gitlab-redis-secret
  namespace: gitlab
type: Opaque
stringData:
  redis-password: ${REDIS_PASSWORD}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: redis-pvc
  namespace: gitlab
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: local-path
  resources:
    requests:
      storage: 1Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: gitlab-redis
  namespace: gitlab
spec:
  replicas: 1
  selector:
    matchLabels:
      app: gitlab-redis
  template:
    metadata:
      labels:
        app: gitlab-redis
    spec:
      containers:
        - name: redis
          image: redis:7
          command: ["redis-server", "--requirepass", "${REDIS_PASSWORD}"]
          ports:
            - containerPort: 6379
          volumeMounts:
            - name: data
              mountPath: /data
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: redis-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: gitlab-redis-master
  namespace: gitlab
spec:
  selector:
    app: gitlab-redis
  ports:
    - port: 6379
      targetPort: 6379
EOF
echo "=== [Step 7c] Redis deployed ==="

kubectl wait --for=condition=available deployment/gitlab-postgresql \
    -n gitlab --timeout=300s
kubectl wait --for=condition=available deployment/gitlab-redis \
    -n gitlab --timeout=300s
echo "=== [Step 7d] PostgreSQL and Redis ready ==="

# upgrade --install = create on first run, update on re-run
helm upgrade --install gitlab gitlab/gitlab \
    --version 10.5.1 \
    --namespace gitlab \
    --timeout 900s \
    --values "${CONFS_DIR}/gitlab-values.yaml" \
    --set global.hosts.externalIP=127.0.0.1 \
    --set gitlab.webservice.service.type=NodePort \
    --set gitlab.webservice.service.nodePort=32080 \
    --set certmanager-issuer.email=admin@gitlab.local \
    --set certmanager.install=false \
    --set certmanager.startupapicheck.enabled=false \
    --set nginx-ingress.enabled=false \
    --set prometheus.install=false \
    --set gitlab-runner.install=false \
    --set registry.enabled=false \
    --set postgresql.install=false \
    --set redis.install=false \
    --set global.psql.host=gitlab-postgresql.gitlab.svc.cluster.local \
    --set global.psql.port=5432 \
    --set global.psql.database=gitlabhq_production \
    --set global.psql.username=gitlab \
    --set global.psql.password.secret=gitlab-postgresql-password \
    --set global.psql.password.key=postgresql-password \
    --set global.redis.host=gitlab-redis-master.gitlab.svc.cluster.local \
    --set global.redis.port=6379 \
    --set global.redis.auth.enabled=true \
    --set global.redis.auth.secret=gitlab-redis-secret \
    --set global.redis.auth.key=redis-password \
    --set global.appConfig.artifacts.enabled=false \
    --set global.appConfig.lfs.enabled=false \
    --set global.appConfig.uploads.enabled=false \
    --set global.appConfig.packages.enabled=false \
    --set global.appConfig.externalDiffs.enabled=false \
    --set global.appConfig.terraformState.enabled=false \
    --set global.appConfig.ciSecureFiles.enabled=false \
    --set global.appConfig.dependencyProxy.enabled=false \
    --set 'global.appConfig.backups.tmpBucket=' \
    --set gitlab.toolbox.enabled=false \
    --set global.ingress.tls.enabled=false \
    --set global.ingress.configureCertmanager=false \
    --set gitlab.webservice.ingress.tls.secretName="" \
    --set gitlab.kas.ingress.tls.secretName="" \
    --set global.kas.enabled=false

echo "=== [Step 7e] GitLab installed/updated ==="

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# STEP 8 — Wait for GitLab
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

echo "=== [Step 8] Waiting for GitLab (10-20 minutes) ==="

echo "  Waiting for migrations job..."
until kubectl get jobs -n gitlab 2>/dev/null | grep -q "migrations"; do
    sleep 5
done

MIGRATIONS_JOB=$(kubectl get jobs -n gitlab \
    --no-headers -o custom-columns=":metadata.name" | grep migrations | head -1)
echo "  Found: $MIGRATIONS_JOB"

kubectl wait --for=condition=complete "job/${MIGRATIONS_JOB}" \
    -n gitlab --timeout=1200s
echo "  Migrations complete"

kubectl wait --for=condition=available deployment/gitlab-webservice-default \
    -n gitlab --timeout=900s

echo "=== [Step 8] GitLab is ready ==="

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# STEP 9 — Configure GitLab
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

echo "=== [Step 9] Configuring GitLab ==="

GITLAB_PASSWORD=$(kubectl get secret gitlab-gitlab-initial-root-password \
    -n gitlab \
    -o jsonpath='{.data.password}' | base64 -d)
echo "  Root password retrieved"

kubectl port-forward -n gitlab \
    svc/gitlab-webservice-default 9090:8181 &
PF_PID=$!
sleep 10

GITLAB_URL="http://localhost:9090"

echo "  Waiting for HTTP on port 9090..."
until curl -sf "$GITLAB_URL/users/sign_in" | grep -q "GitLab" 2>/dev/null; do
    echo "  ...waiting 10s"
    sleep 10
done
echo "  GitLab HTTP is responding"

SIDEKIQ_POD=$(kubectl get pods -n gitlab \
    --no-headers | grep sidekiq | awk '{print $1}' | head -1)
echo "  Using sidekiq pod: $SIDEKIQ_POD"

GITLAB_TOKEN=$(kubectl exec -n gitlab "$SIDEKIQ_POD" \
    -c sidekiq -- \
    /srv/gitlab/bin/rails runner "
token = User.find(1).personal_access_tokens.create(
  name: 'argo-token',
  scopes: ['api', 'read_repository', 'write_repository'],
  expires_at: 365.days.from_now
)
puts token.token
" 2>/dev/null | grep -E '^glpat-[A-Za-z0-9_-]+' | tail -1)

if [ -z "$GITLAB_TOKEN" ]; then
    echo "  Token empty — retrying in 15s..."
    sleep 15
    GITLAB_TOKEN=$(kubectl exec -n gitlab "$SIDEKIQ_POD" \
        -c sidekiq -- \
        /srv/gitlab/bin/rails runner "
t = User.find(1).personal_access_tokens.find_by(name: 'argo-token')
t ||= User.find(1).personal_access_tokens.create(
  name: 'argo-token',
  scopes: ['api', 'read_repository', 'write_repository'],
  expires_at: 365.days.from_now
)
puts t.token
" 2>/dev/null | grep -E '^glpat-[A-Za-z0-9_-]+' | tail -1)
fi

echo "  Personal access token: $GITLAB_TOKEN"

if [ -z "$GITLAB_TOKEN" ]; then
    echo "  FATAL: could not retrieve token. Debug:"
    echo "  kubectl exec -n gitlab $SIDEKIQ_POD -c sidekiq -- /srv/gitlab/bin/rails runner \"puts User.find(1).personal_access_tokens.last.token\""
    exit 1
fi

# Create project only if it does not already exist
PROJECT_ID=$(curl -sf \
    "$GITLAB_URL/api/v4/projects/root%2Fiot" \
    --header "PRIVATE-TOKEN: $GITLAB_TOKEN" 2>/dev/null | jq -r '.id // empty')

if [ -z "$PROJECT_ID" ]; then
    curl -s --request POST \
        "$GITLAB_URL/api/v4/projects" \
        --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
        --header "Content-Type: application/json" \
        --data '{"name":"iot","visibility":"public","initialize_with_readme":false}' \
        > /dev/null
    echo "  Project 'iot' created"
else
    echo "  Project 'iot' already exists (id=${PROJECT_ID}) — skipping"
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# STEP 10 — Push deployment.yaml to GitLab
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

echo "=== [Step 10] Pushing manifests to GitLab ==="

git config --global user.email "root@gitlab.local"
git config --global user.name "root"
git config --global init.defaultBranch main

cd /tmp
rm -rf iot-repo && mkdir iot-repo && cd iot-repo

git init
mkdir -p confs
cp "${CONFS_DIR}/deployment.yaml" confs/
git add .
git commit -m "initial: add deployment manifest"

git remote add origin \
    "http://root:${GITLAB_TOKEN}@localhost:9090/root/iot.git"

# --force handles the case where the repo already has commits from a previous run
git push -u origin main --force

cd /

sudo -u "$REAL_USER" git config --global user.email "root@gitlab.local" 2>/dev/null || true
sudo -u "$REAL_USER" git config --global user.name "root" 2>/dev/null || true
chown -R "$REAL_USER:$REAL_USER" /tmp/iot-repo 2>/dev/null || true

echo "=== [Step 10] Manifests pushed ==="

# Port-forward stays alive — needed for manual git pushes later

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# STEP 11 — Argo CD
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
# STEP 13 — Argo CD Application
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
# STEP 14 — Wait for app
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

echo "=== [Step 14] Waiting for Argo CD to sync ==="

until kubectl get deployment wil-playground -n dev &>/dev/null; do
    echo "  waiting for Argo CD to sync..."
    sleep 5
done

kubectl wait --for=condition=available deployment/wil-playground \
    -n dev --timeout=120s

echo "=== [Step 14] App is running ==="

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# STEP 15 — Summary
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Installation complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo " GitLab UI:       http://localhost:9090 (port-forward already running)"
echo " GitLab user:     root"
echo " GitLab password: ${GITLAB_PASSWORD}"
echo " GitLab repo:     http://localhost:9090/root/iot"
echo ""
echo " Argo CD UI:      https://localhost:8080 (run: argocd-pf first)"
echo " Argo CD user:    admin"
echo " Argo CD pass:    ${ARGOCD_PASS}"
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
curl -s http://localhost:8888/ || echo "(not reachable yet — wait a moment)"
echo ""
echo ""
echo " After a reboot — restart port-forward before pushing:"
echo "   kubectl port-forward -n gitlab svc/gitlab-webservice-default 9090:8181 &"
echo "   (or just run: gitlab-pf)"
echo ""
echo " To switch version:"
echo "   cd /tmp/iot-repo"
echo "   sed -i 's/playground:v1/playground:v2/' confs/deployment.yaml"
echo "   git add . && git commit -m 'update to v2' && git push"
echo "   curl http://localhost:8888/"

GITLAB_ALIAS="alias gitlab-pf='kubectl port-forward -n gitlab svc/gitlab-webservice-default 9090:8181 &'"
ARGOCD_ALIAS="alias argocd-pf='kubectl port-forward -n argocd svc/argocd-server 8080:443 &'"
ARGOCD_PASS=$(kubectl get secret argocd-initial-admin-secret \
    -n argocd \
    -o jsonpath='{.data.password}' | base64 -d)

for RC in "$REAL_HOME/.bashrc" "$REAL_HOME/.zshrc"; do
    if [ -f "$RC" ]; then
        grep -q "gitlab-pf" "$RC" || echo "$GITLAB_ALIAS" >> "$RC"
        grep -q "argocd-pf" "$RC" || echo "$ARGOCD_ALIAS" >> "$RC"
    fi
done

echo ""
echo " Aliases added to shell config (gitlab-pf, argocd-pf)"