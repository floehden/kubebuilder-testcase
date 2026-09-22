#!/usr/bin/env bash
set -euo pipefail

CLUSTER="${CLUSTER:-chaos-demo}"
HTTP_PORT="${HTTP_PORT:-8080}"
INGRESS_NGINX_REF="${INGRESS_NGINX_REF:-controller-v1.11.3}"   # 'main' drifts - pin it
KINV_IMAGE="${KINV_IMAGE:-docker.io/luckysideburn/kubeinvaders:latest}"
DEMO_IMAGE="docker.io/traefik/whoami:v1.10.1"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

# kubectl apply, retried - admission webhooks in a fresh cluster are flaky.
apply_retry() {
  local f="$1" i
  for i in 1 2 3 4 5; do
    kubectl apply -f "$f" && return 0
    echo "   apply failed, retrying in 5s ($i/5)..."
    sleep 5
  done
  return 1
}

for bin in docker kind kubectl; do
  command -v "$bin" >/dev/null || { echo "missing: $bin"; exit 1; }
done
docker info >/dev/null 2>&1 || { echo "docker daemon not reachable from WSL - start Docker Desktop or 'sudo service docker start'"; exit 1; }

say "Raising inotify limits (kind multi-node clusters hit these in WSL)"
sudo sysctl -w fs.inotify.max_user_watches=524288 >/dev/null || true
sudo sysctl -w fs.inotify.max_user_instances=512 >/dev/null || true

if kind get clusters | grep -qx "$CLUSTER"; then
  say "Cluster '$CLUSTER' already exists - reusing it"
else
  say "Creating kind cluster '$CLUSTER'"
  kind create cluster --config "$ROOT/kind/cluster.yaml"
fi

kubectl cluster-info --context "kind-${CLUSTER}" >/dev/null

say "Pre-pulling images into the kind nodes (so restarts are instant during the demo)"
for img in "$DEMO_IMAGE" "$KINV_IMAGE"; do
  docker pull "$img"
  kind load docker-image "$img" --name "$CLUSTER"
done

say "Installing ingress-nginx (kind provider manifest)"
kubectl apply -f "https://raw.githubusercontent.com/kubernetes/ingress-nginx/${INGRESS_NGINX_REF}/deploy/static/provider/kind/deploy.yaml"
# The upstream kind manifest does not reliably carry the ingress-ready
# nodeSelector + control-plane tolerations. Without them the controller can land
# on a worker, where its hostPort 80 binds inside a container that publishes
# nothing to the host - and every curl to localhost:8080 returns 000.
say "Pinning the ingress controller to the node with the published host ports"
kubectl label node "${CLUSTER}-control-plane" ingress-ready=true --overwrite
kubectl -n ingress-nginx patch deploy ingress-nginx-controller --type merge -p '{
  "spec": {"template": {"spec": {
    "nodeSelector": {"kubernetes.io/os": "linux", "ingress-ready": "true"},
    "tolerations": [
      {"key": "node-role.kubernetes.io/control-plane", "operator": "Equal", "effect": "NoSchedule"},
      {"key": "node-role.kubernetes.io/master", "operator": "Equal", "effect": "NoSchedule"}
    ]
  }}}
}'
kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=300s

kubectl -n ingress-nginx wait --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller --timeout=300s

# A Ready controller pod is NOT enough. Until the admission Service has
# endpoints, kube-proxy rejects connections to its ClusterIP and the first
# Ingress apply fails with:
#   failed calling webhook "validate.nginx.ingress.kubernetes.io": connection refused
say "Waiting for the ingress-nginx admission webhook to accept traffic"
kubectl -n ingress-nginx wait --for=condition=complete job --all --timeout=180s || true
for _ in $(seq 1 90); do
  if [ -n "$(kubectl -n ingress-nginx get endpoints ingress-nginx-controller-admission \
              -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)" ]; then
    break
  fi
  sleep 2
done

say "Deploying demo workloads (namespace: shop)"
apply_retry "$ROOT/manifests/demo/shop.yaml"

say "Deploying KubeInvaders"
# Order matters: rbac.yaml creates the namespace. Never 'apply -f <dir>' here,
# that runs alphabetically and deployment.yaml would go first.
kubectl apply -f "$ROOT/manifests/kubeinvaders/rbac.yaml"
kubectl -n kubeinvaders wait --for=jsonpath='{.status.phase}'=Active \
  namespace/kubeinvaders --timeout=60s >/dev/null 2>&1 || true
kubectl apply -f "$ROOT/manifests/kubeinvaders/deployment.yaml"
apply_retry "$ROOT/manifests/kubeinvaders/service-ingress.yaml"

say "Waiting for rollouts"
kubectl -n shop rollout status deploy/frontend --timeout=180s
kubectl -n shop rollout status deploy/cart-api --timeout=180s
kubectl -n shop rollout status deploy/legacy-db --timeout=180s
kubectl -n kubeinvaders rollout status deploy/kubeinvaders --timeout=300s

cat <<EOF

  Ready.

  Game:      http://kubeinvaders.localtest.me:${HTTP_PORT}
  Demo shop: http://shop.localtest.me:${HTTP_PORT}        (frontend, 6 replicas)
             http://shop.localtest.me:${HTTP_PORT}/cart   (slow to become ready)
             http://shop.localtest.me:${HTTP_PORT}/db     (single replica - fragile)

  Second terminal for the demo:
    watch -n1 kubectl get pods -n shop -o wide

  If *.localtest.me does not resolve, add to C:\\Windows\\System32\\drivers\\etc\\hosts:
    127.0.0.1 kubeinvaders.localtest.me shop.localtest.me

EOF