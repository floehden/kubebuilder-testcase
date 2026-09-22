#!/usr/bin/env bash
set -euo pipefail
CLUSTER="${CLUSTER:-chaos-demo}"
docker rm -f kubeinvaders >/dev/null 2>&1 || true
kind delete cluster --name "$CLUSTER"
