#!/usr/bin/env bash
set -euo pipefail

# Fallback / upstream-recommended path: run KubeInvaders OUTSIDE the cluster,
# attached to the "kind" docker network so it can reach the API server.
# Useful if the in-cluster Deployment misbehaves, or if you want to point one
# container at several clusters.

CLUSTER="${CLUSTER:-chaos-demo}"
PORT="${PORT:-8081}"                      # 8080 is taken by the kind ingress mapping
KINV_IMAGE="${KINV_IMAGE:-docker.io/luckysideburn/kubeinvaders:latest}"
TARGET_NS="${TARGET_NS:-shop}"

TOKEN="$(kubectl -n kubeinvaders get secret kinv-sa-token \
  -o go-template='{{.data.token | base64decode}}')"

# Short-lived alternative:
#   TOKEN="$(kubectl create token kinv-sa -n kubeinvaders --duration=8h)"

echo "Starting KubeInvaders on http://localhost:${PORT}"
docker run --rm -it \
  --name kubeinvaders \
  --network kind \
  -p "${PORT}:8080" \
  --env K8S_TOKEN="$TOKEN" \
  --env INSECURE_ENDPOINT=true \
  --env KUBERNETES_SERVICE_HOST="${CLUSTER}-control-plane" \
  --env KUBERNETES_SERVICE_PORT_HTTPS=6443 \
  --env APPLICATION_URL="http://localhost:${PORT}" \
  --env NAMESPACE="${TARGET_NS}" \
  "$KINV_IMAGE"
