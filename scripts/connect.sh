#!/usr/bin/env bash
# Start the tunnel, and optionally build a kubeconfig that points at it.
#
# Usage:
#   export TUNNEL_HOST=... TUNNEL_PREFIX=... TUNNEL_USER=... TUNNEL_PASS=...
#   ./connect.sh                       # starts the tunnel on 127.0.0.1:6443
#
#   SOURCE_KUBECONFIG=~/.kube/test.config ./connect.sh --write-kubeconfig
#
# Env: TUNNEL_HOST, TUNNEL_PREFIX, TUNNEL_USER, TUNNEL_PASS   (required)
#      LOCAL_PORT (default 6443)  DEST (default kubernetes.default.svc:443)
#      WSTUNNEL   (default ~/.local/bin/wstunnel)
#      KUBECONFIG_OUT     where to write the kubeconfig (default ~/.kube/<context>-tunnel.yaml)
#
# The four TUNNEL_* values are handed to you by whoever installed the tunnel -- that chart's install
# output prints them. Nothing on this machine can read them for you: reaching that cluster is the
# whole point of the tunnel, so this machine has no kubeconfig for it yet.
#
# This is the per-developer tunnel: it listens on LOOPBACK and runs in the foreground. For the
# shared service that republishes each backend on a NodePort of a front cluster, see
# charts/k8s-tunnel-client and scripts/front-kubeconfig.sh. The two write differently-named
# kubeconfigs on purpose -- see the suffix note in scripts/lib-kubeconfig.sh.
set -euo pipefail

# Keep these messages free of $(...) -- bash expands `word` inside ${VAR:?word}, so a command
# substitution there is EXECUTED while building the error text.
: "${TUNNEL_HOST:?not set -- ask whoever installed the tunnel for the four TUNNEL_* values}"
: "${TUNNEL_PREFIX:?not set -- ask whoever installed the tunnel for the four TUNNEL_* values}"
: "${TUNNEL_USER:?not set -- ask whoever installed the tunnel for the four TUNNEL_* values}"
: "${TUNNEL_PASS:?not set -- ask whoever installed the tunnel for the four TUNNEL_* values}"

LOCAL_PORT="${LOCAL_PORT:-6443}"
WSTUNNEL="${WSTUNNEL:-$HOME/.local/bin/wstunnel}"

# DEST must match the server's --restrict-to EXACTLY. A mismatch is refused by the server and
# shows up only in ITS logs; from here it just looks like the tunnel is broken.
DEST="${DEST:-kubernetes.default.svc:443}"

WRITE_KUBECONFIG=0
[ "${1:-}" = "--write-kubeconfig" ] && WRITE_KUBECONFIG=1

# --- secrets in argv ----------------------------------------------------------
# `ps` shows every process's arguments to every user on the machine, so anything on the command
# line leaks.
#
#   - The PREFIX is kept out of argv: the client reads
#     WSTUNNEL_HTTP_UPGRADE_PATH_PREFIX natively. Verified working.
#
#   - The PASSWORD cannot be. wstunnel v11 has no env var for --http-upgrade-credentials, and
#     its --http-headers-file alternative was TESTED AND DOES NOT AUTHENTICATE (nginx returns
#     401 -- the Authorization header does not survive). So the password is visible in `ps`
#     on every developer machine that runs this.
#
#     Treat the password as shared material that WILL leak, and rotate it rather than assuming
#     it stays confidential. Do not spend time trying --http-headers-file again.
export WSTUNNEL_HTTP_UPGRADE_PATH_PREFIX="$TUNNEL_PREFIX"

# --- optional: build a kubeconfig -------------------------------------------
if [ "$WRITE_KUBECONFIG" = "1" ]; then
  # shellcheck source=scripts/lib-kubeconfig.sh
  . "$(cd "$(dirname "$0")" && pwd)/lib-kubeconfig.sh"
  # stdout carries the written path; this script has no use for it.
  write_tunneled_kubeconfig "https://127.0.0.1:${LOCAL_PORT}" "-tunnel" >/dev/null
fi

echo "tunnelling 127.0.0.1:${LOCAL_PORT} -> ${DEST} via wss://${TUNNEL_HOST}" >&2
echo "keep this running. Ctrl-C to stop." >&2

exec "$WSTUNNEL" client \
  -L "tcp://127.0.0.1:${LOCAL_PORT}:${DEST}" \
  --http-upgrade-credentials "${TUNNEL_USER}:${TUNNEL_PASS}" \
  "wss://${TUNNEL_HOST}"
