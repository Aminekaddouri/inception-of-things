#!/bin/bash

set -e

echo "=== [Part 3] Starting installation ==="

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# STEP 0 — Install base dependencies
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
    curl \
    wget \
    apt-transport-https \
    ca-certificates \
    gnupg \
    lsb-release

echo "=== [Step 0] Base dependencies installed ==="

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# STEP 1 — Install Docker
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# K3d runs K3s nodes as Docker containers, so Docker is required.
# We use the official Docker install script — simplest and most reliable.

curl -fsSL https://get.docker.com | sh

# Add the current user to the docker group so they can run docker
# without sudo. 'whoami' gets the current user (root during provisioning,
# vagrant when you SSH in manually).
usermod -aG docker vagrant

# Start Docker service and enable it to start on boot
systemctl enable docker
systemctl start docker

echo "=== [Step 1] Docker installed ==="

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# STEP 2 — Install kubectl
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# kubectl is the CLI to talk to Kubernetes.
# We pin to the same version as our K3s in Parts 1&2 for consistency.

curl -LO "https://dl.k8s.io/release/v1.28.15/bin/linux/amd64/kubectl"
chmod +x kubectl
mv kubectl /usr/local/bin/kubectl

echo "=== [Step 2] kubectl installed ==="

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# STEP 3 — Install K3d
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# K3d is a single binary that manages K3s-in-Docker clusters.
# The official install script downloads and places it in /usr/local/bin/k3d.

curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash

echo "=== [Step 3] K3d installed ==="

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# STEP 4 — Create K3d cluster
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# k3d cluster create spins up Docker containers that run K3s inside them.
#
# --port "8888:30000@loadbalancer"
#   Maps port 8888 on your VM host → port 30000 on the K3d load balancer
#   → NodePort 30000 on the cluster node → your app pod
#   This is why curl localhost:8888 reaches the app
#
# --wait
#   Block until the cluster is ready before continuing

k3d cluster create iot \
    --port "8888:30000@loadbalancer" \
    --wait


# K3d automatically updates ~/.kube/config to point kubectl at this cluster
# But since we're running as root, we need to make sure vagrant user can use it too
mkdir -p /home/vagrant/.kube
cp /root/.kube/config /home/vagrant/.kube/config
chown vagrant:vagrant /home/vagrant/.kube/config

echo "=== [Step 4] K3d cluster created ==="


# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# STEP 5 — Create namespaces
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# The subject requires exactly two namespaces:
# - argocd: where Argo CD itself runs
# - dev: where your application runs (managed by Argo CD)

kubectl create namespace argocd
kubectl create namespace dev

echo "=== [Step 5] Namespaces created ==="

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# STEP 6 — Install Argo CD
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# The official Argo CD install manifest creates everything Argo CD needs:
# - argocd-server (the API + UI)
# - argocd-repo-server (clones and reads your Git repo)
# - argocd-application-controller (reconciles cluster state with Git)
# - argocd-dex-server (authentication)
# - argocd-redis (caching)

kubectl apply -n argocd \
    -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml \
    || true

echo "=== [Step 6] Argo CD manifests applied, waiting for it to be ready ==="

# Wait for the main Argo CD server deployment to be fully ready
# This can take 2-3 minutes as it pulls images
kubectl wait --for=condition=available deployment/argocd-server \
    -n argocd --timeout=300s

echo "=== [Step 6] Argo CD is ready ==="

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# STEP 7 — Create the Argo CD Application
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# This tells Argo CD WHAT to watch and WHERE to deploy it.
# We apply it as a Kubernetes manifest (Argo CD adds its own CRDs to K8s).

kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: wil-playground
  namespace: argocd            # Application object lives in argocd namespace
spec:
  project: default

  source:
    repoURL: https://github.com/Aminekaddouri/inception-of-things
    targetRevision: HEAD       # watch the latest commit on main branch
    path: p3/confs             # folder in the repo containing your manifests

  destination:
    server: https://kubernetes.default.svc   # deploy to the same cluster
    namespace: dev             # deploy into the dev namespace

  syncPolicy:
    automated:                 # sync automatically when repo changes
      selfHeal: true           # if cluster drifts from Git, fix it
      prune: true              # remove resources deleted from the repo
    syncOptions:
      - CreateNamespace=true   # create dev namespace if it doesn't exist
EOF

echo "=== [Step 7] Argo CD Application created ==="

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# STEP 8 — Wait for app to deploy in dev namespace
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Argo CD needs a moment to clone the repo and apply the manifests.
# We wait until the Deployment exists before running kubectl wait on it.

echo "=== [Step 9] Waiting for app to deploy ==="

# Wait for Argo CD to create the deployment (it may take up to 30s to sync)
until kubectl get deployment wil-playground -n dev &>/dev/null; do
    echo "  waiting for Argo CD to sync..."
    sleep 5
done

# Now wait for it to be ready
kubectl wait --for=condition=available deployment/wil-playground \
    -n dev --timeout=120s

echo "=== [Step 8] App is running ==="


# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# STEP 9 — Print summary
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Installation complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo " Namespaces:"
kubectl get namespaces
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
echo " Argo CD UI:  kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "              then open https://localhost:8080 (user: admin)"
echo " Argo CD password:"
kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath="{.data.password}" | base64 -d
echo ""