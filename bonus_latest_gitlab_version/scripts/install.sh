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

# STEP 0 — Base dependencies
apt-get update -qq
apt-get install -y -qq curl wget git jq apt-transport-https \
    ca-certificates gnupg lsb-release

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
# Helm is the package manager for Kubernetes
# We need it to install GitLab (too complex to install manually)

curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

echo "=== [Step 4] Helm installed ==="

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# STEP 5 — Create K3d cluster
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 8888:30000 → wil-playground app
# 8181:32080 → GitLab (NodePort mapping, actual access via port-forward)

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

# STEP 7 — Install PostgreSQL + Redis + GitLab
# Using official postgres:15 and redis:7 images

helm repo add gitlab https://charts.gitlab.io
helm repo update

echo "=== [Step 7a] Helm repo added ==="

PG_PASSWORD=$(openssl rand -base64 16)
REDIS_PASSWORD=$(openssl rand -base64 16)

# ── PostgreSQL using official image ──────────────────────────────────────────
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

# ── Redis using official image ────────────────────────────────────────────────
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

# Wait for PostgreSQL and Redis — 300s because image pull can take ~2 min
kubectl wait --for=condition=available deployment/gitlab-postgresql \
    -n gitlab --timeout=300s
kubectl wait --for=condition=available deployment/gitlab-redis \
    -n gitlab --timeout=300s
echo "=== [Step 7d] PostgreSQL and Redis ready ==="

# ── Install GitLab chart v7.11.10 (GitLab v16.11) ────────────────────────────
# This version works with external PostgreSQL and Redis
# Minio will fail (ImagePullBackOff) but that's OK — we don't need it
# git operations work without Minio
helm install gitlab gitlab/gitlab \
    --version 10.5.1 \
    --namespace gitlab \
    --timeout 900s \
    --values /vagrant/confs/gitlab-values.yaml \
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
echo "=== [Step 7e] GitLab installed ==="

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# STEP 8 — Wait for GitLab to be ready
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# GitLab has multiple components that must all be ready
# We wait for the webservice (main component) last

echo "=== [Step 8] Waiting for GitLab (10-15 minutes) ==="

echo "  Waiting for migrations job..."
until kubectl get jobs -n gitlab | grep -q "migrations"; do
    sleep 5
done

MIGRATIONS_JOB=$(kubectl get jobs -n gitlab \
    --no-headers -o custom-columns=":metadata.name" | grep migrations)
echo "  Found: $MIGRATIONS_JOB"

# 1200s = 20 minutes — GitLab v19 migrations are slow
kubectl wait --for=condition=complete job/$MIGRATIONS_JOB \
    -n gitlab --timeout=1200s
echo "  Migrations complete"

kubectl wait --for=condition=available deployment/gitlab-webservice-default \
    -n gitlab --timeout=900s

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

# Use port-forward on 9090 — NodePort 8181 doesn't route correctly
# The webservice internal port is 8181 so we forward to that
kubectl port-forward -n gitlab \
    svc/gitlab-webservice-default 9090:8181 &
PF_PID=$!
sleep 10

# GitLab URL — accessible from inside the VM via port-forward
GITLAB_URL="http://localhost:9090"

# Wait for GitLab HTTP to actually respond
# (the deployment being "available" doesn't mean HTTP is ready yet)
echo "  Waiting for HTTP on port 9090..."
until curl -sf "$GITLAB_URL/users/sign_in" | \
    grep -q "GitLab" 2>/dev/null; do
    echo "  ...waiting 10s"
    sleep 10
done

echo "  GitLab HTTP is responding"

# REPLACE the entire token creation block in Step 9 with this:

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

# Verify token was actually created
if [ -z "$GITLAB_TOKEN" ]; then
    echo "  ERROR: token creation failed, retrying in 15s..."
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

echo "  Personal access token created: $GITLAB_TOKEN"

if [ -z "$GITLAB_TOKEN" ]; then
    echo "  FATAL: could not retrieve token. Debug with:"
    echo "  kubectl exec -n gitlab $SIDEKIQ_POD -c sidekiq -- /srv/gitlab/bin/rails runner \"puts User.find(1).personal_access_tokens.last.token\""
    exit 1
fi

# Create a project (repository) named 'iot'
curl -s --request POST \
    "$GITLAB_URL/api/v4/projects" \
    --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
    --header "Content-Type: application/json" \
    --data '{"name":"iot","visibility":"public","initialize_with_readme":false}' \
    > /dev/null

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
rm -rf iot-repo && mkdir iot-repo && cd iot-repo

git init
mkdir -p confs
cp /vagrant/confs/deployment.yaml confs/
git add .
git commit -m "initial: add deployment manifest"

# Push via port-forward on 9090
git remote add origin \
    "http://root:$GITLAB_TOKEN@localhost:9090/root/iot.git"

git push -u origin main

cd /

chown -R vagrant:vagrant /tmp/iot-repo

# Set git config for vagrant user as well
sudo -u vagrant git config --global user.email "root@gitlab.local"
sudo -u vagrant git config --global user.name "root"

echo "=== [Step 10] Manifests pushed to local GitLab ==="

# Kill port-forward — no longer needed
# kill $PF_PID 2>/dev/null || true

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
    path: confs              # folder in our local repo
  
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

# kubectl port-forward -n gitlab \
#     svc/gitlab-webservice-default 9090:8181 &
# PF_PID=$!
# sleep 10

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# STEP 15 — Print summary
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Installation complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo " GitLab UI:       http://localhost:9090 (via port-forward)"
echo " GitLab user:     root"
echo " GitLab password: $GITLAB_PASSWORD"
echo " GitLab repo:     http://localhost:9090/root/iot"
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
echo " To switch version — run inside VM:"
echo "   # Start port-forward first if not running:"
echo "   kubectl port-forward -n gitlab svc/gitlab-webservice-default 9090:8181 &"
echo "   # Then push:"
echo "   cd /tmp/iot-repo"
echo "   sed -i 's/playground:v1/playground:v2/' confs/deployment.yaml"
echo "   git add . && git commit -m 'update to v2' && git push"
echo "   # Wait ~3 min then:"
echo "   curl http://localhost:8888/"

echo "alias gitlab-pf='kubectl port-forward -n gitlab svc/gitlab-webservice-default 9090:8181 &'" \
    >> /home/vagrant/.bashrc