#!/usr/bin/env bash
set -euo pipefail

# Prints every value KubeInvaders needs to talk to the cluster.
#   ./scripts/connection-info.sh          # values, token masked
#   ./scripts/connection-info.sh --token  # full token (for pasting)

CLUSTER="${CLUSTER:-chaos-demo}"
SHOW_TOKEN=false
[ "${1:-}" = "--token" ] && SHOW_TOKEN=true

TOKEN="$(kubectl -n kubeinvaders get secret kinv-sa-token \
  -o go-template='{{.data.token | base64decode}}' 2>/dev/null || true)"
[ -n "$TOKEN" ] || { echo "kinv-sa-token not found - apply manifests/kubeinvaders/rbac.yaml first"; exit 1; }

EXT_SERVER="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
API_IP="$(kubectl -n default get svc kubernetes -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo '10.96.0.1')"
NS="$(kubectl -n kubeinvaders get deploy kubeinvaders \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="NAMESPACE")].value}' 2>/dev/null || echo '-')"

if $SHOW_TOKEN; then TOKEN_OUT="$TOKEN"; else TOKEN_OUT="${TOKEN:0:24}...  (re-run with --token)"; fi

cat <<EOF

IN-CLUSTER (what the running Deployment uses - nothing to enter anywhere)
  API server          https://kubernetes.default.svc:443
  KUBERNETES_SERVICE_HOST / _PORT_HTTPS   injected by kubelet
  Credential          /var/run/secrets/kubernetes.io/serviceaccount/token (SA kinv-sa)
  TLS verification    off via DISABLE_TLS=true (the var nginx/Lua actually reads;
                      INSECURE_ENDPOINT is not in nginx.conf's env list)
  Target namespaces   ${NS}

OUT-OF-CLUSTER (scripts/run-kubeinvaders-docker.sh, or another chaos tool)
  From the 'kind' docker network:
    KUBERNETES_SERVICE_HOST        ${CLUSTER}-control-plane
    KUBERNETES_SERVICE_PORT_HTTPS  6443
  From WSL / your kubeconfig:
    server                         ${EXT_SERVER}
  Token (ServiceAccount kubeinvaders/kinv-sa, non-expiring):
    ${TOKEN_OUT}

IN THE BROWSER (connection dialog)
  The connection test runs FROM THE POD, not from your browser - so host-side
  addresses like https://127.0.0.1:${EXT_SERVER##*:} or https://localhost:6443
  fail with "502 (connection refused)". Use the in-cluster address:

    Endpoint    https://kubernetes.default.svc:443
    (or)        https://${API_IP}:443
    Token       see above (--token to print it in full)
    Namespaces  ${NS}

HANDY
  Test the endpoint from inside the pod (expect 200):
    kubectl -n kubeinvaders exec deploy/kubeinvaders -- sh -c \\
      'curl -sk -o /dev/null -w "%{http_code}\\n" \\
       -H "Authorization: Bearer \$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \\
       https://kubernetes.default.svc:443/api/v1/namespaces/shop/pods'
  Fresh short-lived token:   kubectl create token kinv-sa -n kubeinvaders --duration=8h
  Verify the token works:    kubectl auth can-i delete pods -n shop \\
                               --as=system:serviceaccount:kubeinvaders:kinv-sa
  Change target namespaces:  kubectl -n kubeinvaders set env deploy/kubeinvaders NAMESPACE=shop,default

EOF