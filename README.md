# KubeInvaders chaos showcase on kind (WSL2)

A self-contained chaos-engineering demo: a 4-node kind cluster, three workloads with
deliberately different resilience profiles, and KubeInvaders as the gamified pod killer.

```
kubeinvaders-kind-showcase/
├── kind/cluster.yaml                     # 1 control-plane (ingress) + 3 workers
├── manifests/demo/shop.yaml              # frontend / cart-api / legacy-db + ingress
├── manifests/kubeinvaders/               # rbac, deployment, service + ingress
└── scripts/                              # setup, teardown, standalone-docker variant
```

## Prerequisites (WSL2)

1. **Docker reachable from WSL** — either Docker Desktop with WSL integration enabled
   for your distro (Settings → Resources → WSL Integration), or docker-ce installed
   inside WSL (`sudo service docker start`, or `systemd=true` in `/etc/wsl.conf`).
2. **Give WSL enough headroom.** A 4-node kind cluster plus ingress wants ~6–8 GB.
   Create `C:\Users\<you>\.wslconfig`:
   ```ini
   [wsl2]
   memory=8GB
   processors=4
   ```
   then `wsl --shutdown` from PowerShell.
3. **kind + kubectl** in WSL:
   ```bash
   [ $(uname -m) = x86_64 ] && curl -Lo ./kind https://kind.sigs.k8s.io/dl/latest/kind-linux-amd64
   chmod +x ./kind && sudo mv ./kind /usr/local/bin/kind
   curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
   chmod +x kubectl && sudo mv kubectl /usr/local/bin/
   ```

## Quickstart

```bash
chmod +x scripts/*.sh
./scripts/setup.sh
```

Then, from your Windows browser:

| What | URL |
| --- | --- |
| The game | http://kubeinvaders.localtest.me:8080 |
| Demo frontend (6 replicas) | http://shop.localtest.me:8080 |
| cart-api (20 s readiness) | http://shop.localtest.me:8080/cart |
| legacy-db (1 replica) | http://shop.localtest.me:8080/db |

`*.localtest.me` resolves to `127.0.0.1` through public DNS, so no hosts-file edit is
needed — unless you're on a corporate resolver that rewrites it, in which case add the
two names to `C:\Windows\System32\drivers\etc\hosts`.

Tear down with `./scripts/teardown.sh`.

## Connection data

Recent versions present a **connection dialog** asking for a Kubernetes API endpoint
and a token. The critical detail: that connection test is executed by the
KubeInvaders pod, not by your browser. Host-side addresses — `https://127.0.0.1:<kind
port>`, `https://localhost:6443` — resolve to the pod's own loopback and fail with
`502 (connection refused)`. Use the in-cluster address instead:

| Field | Value |
| --- | --- |
| Endpoint | `https://kubernetes.default.svc` (the pod resolves this; host-side addresses fail) |
| Token | `./scripts/connection-info.sh --token` |
| Namespaces | `shop` (must exist and contain pods) |

TLS: the connection test is executed by nginx + LuaSec inside the pod, and it verifies
against the system CA bundle, which does not contain kind's CA. The env var that turns
verification off is **`DISABLE_TLS=true`** — it's declared in the `env` list of
`nginx.conf` and maps to LuaSec's `verify = "none"`. `INSECURE_ENDPOINT` is not in that
list and has no effect on this path, despite appearing in upstream docs. Both are set
in `deployment.yaml`.

To inspect how the check is wired in whatever image version you end up with:

```bash
kubectl -n kubeinvaders exec deploy/kubeinvaders -- grep -n '^env' /etc/nginx/nginx.conf
kubectl -n kubeinvaders exec deploy/kubeinvaders -- \
  grep -niE 'verify|cafile|healthz' /etc/nginx/conf.d/KubeInvaders.conf
```

```bash
./scripts/connection-info.sh          # all values, token masked
./scripts/connection-info.sh --token  # full token
```

| | In-cluster (this Deployment) | Out-of-cluster (docker run) |
| --- | --- | --- |
| API host | injected `KUBERNETES_SERVICE_HOST` | `chaos-demo-control-plane` (on the `kind` docker network) |
| API port | injected `KUBERNETES_SERVICE_PORT_HTTPS` | `6443` |
| Credential | mounted SA token, `kinv-sa` | `K8S_TOKEN` from the `kinv-sa-token` Secret |
| TLS | `INSECURE_ENDPOINT=true` | `INSECURE_ENDPOINT=true` |
| Namespaces | `NAMESPACE=shop,default` | `NAMESPACE=shop` |
| Self URL | `APPLICATION_URL` / `ENDPOINT` | `http://localhost:8081` |

`INSECURE_ENDPOINT=true` is needed because kind's API server certificate isn't in the
container's trust store. Fine for a laptop demo; don't carry that setting anywhere real.

Confirm the service account can actually do the thing before you demo:

```bash
kubectl auth can-i delete pods -n shop \
  --as=system:serviceaccount:kubeinvaders:kinv-sa     # expect: yes
```

To retarget the game at different namespaces:

```bash
kubectl -n kubeinvaders set env deploy/kubeinvaders NAMESPACE=shop,default
```

## The demo, as a talk track (~10 min)

Run `watch -n1 kubectl get pods -n shop -o wide` in a second window, side by side with
the browser. The cluster state reacting in real time is what sells it.

1. **Frame it.** Open the shop — `whoami` prints the pod name that served the request.
   Refresh a few times: different pods answer. Six replicas, spread over three workers.
2. **Open the game**, target namespace `shop`. Each alien is a pod. Press `h` for the
   key bindings, `i` to show pod names under the aliens.
3. **Turn on the HTTP check** ("Add HTTP check & Chaos Report") pointing at
   `http://shop.localtest.me:8080`. You now have a live availability chart to correlate
   against your kills.
4. **Shoot frontend pods.** The site never blinks; the ReplicaSet refills from three
   nodes. This is the boring, correct outcome — say so out loud.
5. **Shoot `legacy-db`.** One replica, instant 503 on `/db`, and a visible gap in the
   chart until the new pod is ready. Single points of failure aren't theoretical.
6. **Shoot `cart-api`.** It comes back, but the 20 s readiness delay shows up as a
   long recovery. Point at "Current Replicas State Delay" — that's the metric that
   maps to your real MTTR.
7. **Autopilot + shuffle.** Let it run while you talk. Crank the difficulty via
   `ALIENPROXIMITY` / `HITSLIMIT` / `UPDATETIME` in the Deployment if you want the
   room to lose.
8. **Land the lesson.** The PDB on `frontend` did nothing — a PDB guards *evictions*
   (drains, upgrades), not `DELETE` calls. What actually helped: replicas > 1, spread
   across nodes, fast readiness probes, and images already on the node.

## Metrics (optional extra act)

KubeInvaders exposes Prometheus metrics on `/metrics` — `deleted_pods_total`,
`deleted_namespace_pods_count`, `chaos_jobs_node_count`. Scrape target:

```yaml
scrape_configs:
  - job_name: kubeinvaders
    static_configs:
      - targets: ["kubeinvaders.kubeinvaders.svc.cluster.local:8080"]
```

There's a ready-made Grafana dashboard in the upstream repo under
`confs/grafana/KubeInvadersDashboard.json`. Install kube-prometheus-stack in the kind
cluster if you want the full observability story alongside the game.

## Things that will bite you

- **Upstream dropped Helm.** The README now says "Helm installation is currently not
  supported" and points at `docker run`/`podman run`. The manifests here are the
  in-cluster equivalent of what the old chart deployed; `scripts/run-kubeinvaders-docker.sh`
  is the upstream-blessed out-of-cluster variant if the in-cluster one gives you trouble.
- **The namespace must be `kubeinvaders`.** Installing into any other namespace is
  explicitly unsupported.
- **Token expiry.** The in-cluster Deployment uses the projected SA token and is fine.
  For the docker variant, prefer the long-lived `kinv-sa-token` Secret over
  `kubectl create token`, or your demo dies after the duration you set.
- **Don't attack nodes on kind.** Node chaos launches a privileged chaos container
  against the node; your "nodes" are the Docker containers hosting the whole demo.
  Keep the showcase to pods, or accept that you may have to rebuild the cluster.
- **No aliens?** `kubectl logs -n kubeinvaders deploy/kubeinvaders -f`, then check the
  namespace really has pods, and that the browser console isn't showing failed calls to
  `/kube/pods?action=list&namespace=shop`.
- **`curl` returns `000`.** Nothing is listening on the port. Two causes seen in
  practice: the ingress controller scheduled onto a worker (its hostPort then binds
  in a container that publishes nothing — `setup.sh` now patches the nodeSelector to
  prevent this), or name resolution. WSL regenerates `/etc/hosts` from the Windows
  hosts file only at distro start, so after editing
  `C:\Windows\System32\drivers\etc\hosts` you need `wsl --shutdown`, or add the entry
  inside WSL directly:
  ```bash
  echo "127.0.0.1 shop.localtest.me kubeinvaders.localtest.me" | sudo tee -a /etc/hosts
  ```
  Ladder for diagnosing: `curl -v http://localhost:8080` (a 404 here is success —
  ingress answered, no host matched) → `getent hosts shop.localtest.me` →
  `docker ps --filter name=chaos-demo-control-plane --format '{{.Ports}}'` →
  `kubectl -n ingress-nginx get pods -o wide`.
- **`GET /kube/pods` returns 500, no aliens.** Check the pod log for
  `pod.lua:254: attempt to compare number with nil`. That's an upstream bug, not a
  misconfiguration: the `elseif` branch calls `tonumber(pods_not_running_on)` without
  the `ngx.null` guard the `if` above it has, so an unset Redis counter crashes the
  handler. `deployment.yaml` seeds the counters in a `postStart` hook. To fix a running
  pod by hand:
  ```bash
  kubectl -n kubeinvaders exec deploy/kubeinvaders -- \
    redis-cli setnx pods_not_running_on_selected_ns 0
  ```
  Redis isn't persisted here, so the keys vanish on every restart.
- **`too many open files` when creating the cluster** is the classic WSL inotify limit;
  `setup.sh` raises it, but make it permanent in `/etc/sysctl.conf` if you rebuild often.
- **This is a toy for teaching.** For actual experiment hygiene — steady-state
  hypotheses, blast-radius control, scheduled runs — reach for Chaos Mesh or LitmusChaos.
  KubeInvaders is what gets people in the room to care.

## Making it GitOps-native

If you want this reconciled by Flux rather than `kubectl apply`, the three
`manifests/` directories drop straight into a `Kustomization` each. Keep the kind
cluster creation out of Git (it's bootstrap), and let Flux own `shop/` and
`kubeinvaders/` — which also makes a nice second act: kill pods, then delete the whole
Deployment and watch the reconciler put it back.