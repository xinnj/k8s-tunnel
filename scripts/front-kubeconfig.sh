#!/usr/bin/env bash
# Build a kubeconfig that reaches a BACKEND cluster through the front-cluster tunnel service.
#
# Usage:
#   BACKEND=test FRONT_NODE_IP=10.0.0.5 ./scripts/front-kubeconfig.sh
#
# Env: BACKEND           (required) which backend; must match a Service port name
#      FRONT_NODE_IP     (required) any node IP of the FRONT cluster
#      NODE_PORT         skip the Service lookup and use this port
#      SOURCE_KUBECONFIG (required) a kubeconfig for the BACKEND cluster
#      NS, RELEASE       where the front chart lives (default k8s-tunnel-client)
#      KUBECONFIG_OUT    where to write it (default ~/.kube/<context>-svc-tunnel.config)
#
# The NodePort is stable: it is pinned in the chart, so it survives upgrades and reinstalls. The
# NODE IP is not. A NodePort answers on ANY node, but this kubeconfig pins one address, so
# draining or removing that node breaks it even though the tunnel is perfectly healthy. Pick a
# node that is not going anywhere.
#
# This script needs BACKEND cluster access: the CA comes from the backend's kube-root-ca.crt, and
# the credentials carried across are the user's own. That is deliberate. A kubeconfig embeds a
# real identity, which is exactly why the front-cluster service does not generate them.
set -euo pipefail

: "${BACKEND:?set BACKEND to the backend name (a Service port name on the front cluster)}"
: "${FRONT_NODE_IP:?set FRONT_NODE_IP to any node IP of the front cluster}"
: "${SOURCE_KUBECONFIG:?set SOURCE_KUBECONFIG to an existing kubeconfig for the BACKEND cluster}"

NS="${NS:-k8s-tunnel-client}"
RELEASE="${RELEASE:-k8s-tunnel-client}"

if [ -z "${NODE_PORT:-}" ]; then
  NODE_PORT="$(kubectl -n "$NS" get svc "$RELEASE" \
    -o jsonpath="{.spec.ports[?(@.name=='${BACKEND}')].nodePort}")"
  if [ -z "$NODE_PORT" ]; then
    echo "ERROR: service '${RELEASE}' in namespace '${NS}' has no port named '${BACKEND}'." >&2
    echo "       Known backends:" >&2
    kubectl -n "$NS" get svc "$RELEASE" \
      -o jsonpath='{range .spec.ports[*]}         {.name}{"\n"}{end}' >&2
    echo "       Add one in the chart's values.yaml, then helm upgrade." >&2
    exit 1
  fi
fi

# shellcheck source=scripts/lib-kubeconfig.sh
. "$(cd "$(dirname "$0")" && pwd)/lib-kubeconfig.sh"

SERVER="https://${FRONT_NODE_IP}:${NODE_PORT}"
echo "backend '${BACKEND}' is published at ${SERVER}" >&2

# "-svc-tunnel", NOT "-tunnel". connect.sh already writes <context>-tunnel for its own loopback
# tunnel, against the same context but a different server. If the two shared a name, ~/.kube would
# hold two files declaring one cluster name with different servers -- the collision that cannot be
# corrected afterwards.
KC="$(write_tunneled_kubeconfig "$SERVER" "-svc-tunnel")"

echo >&2
echo "checking the tunnel is actually reachable..." >&2
if kubectl --kubeconfig "$KC" --request-timeout=15s get namespaces >/dev/null 2>&1; then
  echo "OK -- the NodePort reaches the backend API server." >&2
else
  echo "WARNING: could not reach the backend through ${SERVER}." >&2
  echo "  The kubeconfig is written and may still work later. Check, in order:" >&2
  echo "    - is the front service healthy?  kubectl -n ${NS} logs deploy/${RELEASE}" >&2
  echo "    - is ${FRONT_NODE_IP} reachable from here on port ${NODE_PORT}?" >&2
  echo "    - is ${FRONT_NODE_IP} still a node of the front cluster?" >&2
fi

echo >&2
echo "use:  kubectl --kubeconfig '$KC' get nodes" >&2
