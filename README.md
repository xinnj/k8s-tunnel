# k8s-tunnel

Reach a Kubernetes API server with `kubectl` and `helm` over an **existing, shared port 443** —
without touching the load balancer.

Built for the case where an external load balancer terminates TLS (L7) and cannot be reconfigured.
That single constraint rules out the four obvious approaches:

| Approach | Why it fails |
|---|---|
| SNI / TLS passthrough | The LB already terminated the handshake |
| HTTP `CONNECT` proxy | Plain nginx does not proxy `CONNECT` — only a patched build does |
| SSH bastion | Raw TCP needs a dedicated port the LB will never forward |
| mTLS client certs | The LB consumes client certificates; they never reach nginx |

What survives is **WebSocket**, which nginx proxies natively. A `wstunnel` server runs
in-cluster carrying **raw TCP** over WebSocket, so kubectl's own TLS handshake with the API
server happens end-to-end *inside* the tunnel. Because the bytes are opaque, `exec`,
`port-forward` and `logs -f` all work — an L7 proxy that re-originates HTTP would break them.

```
kubectl → 127.0.0.1:6443 → wstunnel client ──wss://host/<PREFIX>──> LB → nginx → wstunnel → kube-apiserver
                                                  │                    │        │
                                          terminated here         basic auth   --restrict-to
```

## Layout

```
charts/k8s-tunnel-server/   Helm chart — the server side; one per BACKEND cluster
charts/k8s-tunnel-client/   Helm chart — tunnel clients on a FRONT cluster, one NodePort per backend
scripts/                    Client-side tooling
tests/                      Test suites: helm template + yq assertions, POSIX sh unit tests
docs/specs/, docs/plans/    Design specs and implementation plans
```

## Server side

Once per cluster you want to reach:

```bash
helm install k8s-tunnel-server charts/k8s-tunnel-server \
  -n k8s-tunnel-server --create-namespace \
  --set ingress.host=<your-shared-hostname>
```

`ingress.host` is required — rendering **fails loudly** without it rather than emitting a
host-less rule, which would silently land in nginx's default server block instead of your vhost.

`pathPrefix` and `basicAuth.password` are **generated on first install and preserved on every later
upgrade**. The install output prints a `kubectl get secret` command for each one — run those where
you have cluster access, then hand the four values to whoever needs them. There is deliberately no
script for that: the people who need the values are the ones who cannot reach the cluster.

`helm uninstall` deliberately leaves both Secrets behind (`helm.sh/resource-policy: keep`) so a
reinstall recovers the same prefix instead of breaking every client.

By default nginx serves plain HTTP, because the design assumes a load balancer in front terminates
TLS. If the cluster is exposed directly instead, with nothing in front of nginx, turn TLS on at the
Ingress:

```bash
  --set ingress.tls.enabled=true \
  --set ingress.tls.secretName=<cert-secret> \
  --set ingress.annotations."cert-manager\.io/cluster-issuer"=<issuer>   # optional, cert-manager
```

This chart does not create the certificate — it names the Secret that must exist. Leave the issuer
annotation out if you create that Secret yourself, and leave `secretName` out entirely if the
controller runs with `--default-ssl-certificate`: the `tls:` block is still emitted, so HTTPS is
still forced and that default certificate is served. Without a `tls:` block at all nginx would serve
the default certificate too, but would *not* force the redirect — which is the reason the block is
worth emitting even when it names no Secret.

`ingress.forceSSLRedirect` is a separate, opposite-direction knob and defaults to false: it forces a
redirect when TLS is terminated *before* nginx, which loops forever unless that load balancer
forwards `X-Forwarded-Proto`. It neither causes nor suppresses the redirect that ingress-nginx
already does on its own once `ingress.tls.enabled` is true.

The image is the official `ghcr.io/erebe/wstunnel`, pinned by tag. Only the destinations listed in
`restrictTo` are forwardable, enforced by wstunnel itself — so it holds whatever the CNI is, unlike
a NetworkPolicy that plain flannel silently ignores. If ghcr.io is unreachable from your network,
point `image.repository` at a mirror.

## Client side

The per-developer tunnel: one process, loopback, one cluster, in the foreground.

```bash
scripts/install-client.sh                 # fetch the wstunnel client (version must match the server)
export TUNNEL_HOST=... TUNNEL_PREFIX=...  # the four values, from whoever installed the tunnel
export TUNNEL_USER=... TUNNEL_PASS=...
scripts/connect.sh --write-kubeconfig     # needs SOURCE_KUBECONFIG=... to build the kubeconfig
```

Then `kubectl --kubeconfig ~/.kube/<context>-tunnel.yaml get nodes`.

The kubeconfig points at `https://127.0.0.1:6443` with `tls-server-name: kubernetes.default.svc`
and the CA from the cluster's `kube-root-ca.crt`. Inside the tunnel kubectl does a real TLS
handshake with the real API server, so **verification is genuine** — no
`insecure-skip-tls-verify`.

## Running the client as a service on a front cluster

`connect.sh` is per-developer. To run the client **once**, on a cluster your users are already on,
`charts/k8s-tunnel-client` holds one outbound tunnel per backend cluster and republishes each on a
NodePort of *that* cluster.

```
consumer → <front-node-ip>:<nodePort> → front-cluster pod → wss://host/<PREFIX> → LB → nginx → wstunnel → kube-apiserver
                                         (one wstunnel client per backend)
```

One Deployment, one replica, and a POSIX-sh supervisor spawning one `wstunnel client` per backend;
plus one `Service type: NodePort` carrying a port per backend. It runs the **same image** as the
server, so there is nothing to build and the client/server protocol cannot drift.

NodePort, not Ingress, and that is forced: the tunnel carries raw TCP, so kubectl's TLS handshake
terminates at the *backend* API server. An L7 hop would re-originate it and break `exec`,
`port-forward` and `logs -f`.

```bash
helm install k8s-tunnel-client charts/k8s-tunnel-client \
  -n k8s-tunnel-client --create-namespace \
  -f my-backends.yaml
```

`backends` in `values.yaml` is the source of truth — one entry per backend, rendered into both the
ConfigMap and the Service. **`nodePort` is pinned per backend, never auto-allocated**: an allocated
port is sticky for the Service's lifetime but not reproducible, so a reinstall would hand out a
different port and silently invalidate every kubeconfig already in circulation.

Each entry's `host`, `prefix`, `user` and `password` are the BACKEND's, and come from that chart's
install output. Copy them in rather than inventing them — a mismatch is refused at the websocket
handshake, and the only diagnostic is in the server's logs.

Then, from a machine holding the BACKEND's kubeconfig and able to reach the front cluster:

```bash
BACKEND=test FRONT_NODE_IP=<any-front-node-ip> ./scripts/front-kubeconfig.sh
```

That writes `<context>-svc-tunnel.config` — deliberately **not** `<context>-tunnel`, which is what
`connect.sh` writes for its loopback tunnel. Same context, different server: sharing a name would
put two files declaring one cluster name with different servers in `~/.kube`, and `kubectl` has no
`rename-cluster`, so it cannot be corrected afterwards.

> ⚠️ **These NodePorts are not authenticated.** A `wstunnel` client is a dumb relay — it terminates
> nothing and verifies nothing. The backend's prefix and password authenticate *this pod to the
> backend*; they are **not** a control on inbound users here. Anyone who can reach a NodePort has
> raw TCP to that backend's API server, stopped only by that cluster's own Kubernetes credentials.
> Confine the Service to a trusted network.

## Tests

```bash
tests/run.sh        # needs helm, yq v4 and htpasswd; no cluster and no credentials
```

The supervisor suite runs under **both** `dash` and `sh`, because dash is the `/bin/sh` the
container actually uses and macOS `/bin/sh` is bash in sh-mode — it would happily accept bashisms
the image rejects. Missing tools are a hard failure, never a skip.

`yq` is the only new dependency. Try `brew install yq` first. If brew has no bottle on your
platform it falls back to building from source plus a Go upgrade; take the release binary instead:

```bash
curl -fsSL -o /tmp/yq https://github.com/mikefarah/yq/releases/download/v4.53.6/yq_darwin_arm64
install -m 0755 /tmp/yq "$HOME/.local/bin/yq"
```

`htpasswd` is needed only by the server-chart suite, to check that the password stored for
retrieval is the one nginx actually validates. macOS ships it at `/usr/sbin/htpasswd`; on Linux it
comes from `apache2-utils` or `httpd-tools`. That suite **fails** rather than skipping if it is
missing.
