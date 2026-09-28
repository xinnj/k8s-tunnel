#!/bin/sh
# Supervisor for the k8s-tunnel-client chart.
#
# NOT executed directly. ConfigMap files are mounted mode 0644, so the chart invokes it as:
#   /usr/bin/dumb-init -- /bin/sh /etc/tunnel/scripts/_supervisor.sh
# dumb-init stays PID 1 so it reaps zombies and forwards signals.
#
# It starts ONE `wstunnel client` per backend config file, each in its own restart loop, so an
# unreachable backend does not disturb the others. A crash-looping backend is deliberately NOT
# allowed to make the pod unready: that would black out the backends that still work. Per-backend
# status is in the LOGS, not in the pod's Ready state.
#
# POSIX sh ONLY -- the image's /bin/sh is dash. No bash, no curl, no nc, no /dev/tcp, no arrays.
# WSTUNNEL_BIN, BACKENDS_DIR and RESTART_DELAY are overridable so the tests can drive this
# without a container.

WSTUNNEL_BIN="${WSTUNNEL_BIN:-/home/app/wstunnel}"
BACKENDS_DIR="${BACKENDS_DIR:-/etc/tunnel/backends}"
RESTART_DELAY="${RESTART_DELAY:-5}"

log() { printf '[supervisor] %s\n' "$*"; }

# A mount that did not arrive must be LOUD. Exiting makes the container restart visibly
# (CrashLoopBackOff) instead of running a pod that looks healthy with zero tunnels up.
if [ ! -d "$BACKENDS_DIR" ]; then
  log "FATAL: $BACKENDS_DIR is not a directory -- did the ConfigMap volume mount?"
  exit 1
fi

# Collect the config files. `[ -f ]` filters out the ConfigMap volume plumbing (`..data` and
# `..20xx_xx_xx`), which are a symlink-to-directory and directories respectively.
#
# Names starting with `_` are skipped as a second line of defence: the supervisor itself ships in
# the same ConfigMap under `_supervisor.sh`, and a volume mounted WITHOUT an explicit `items` list
# would expose it here and make the supervisor `.`-source itself. Backend names are constrained to
# [a-z0-9-] by the chart, so no valid backend can be skipped by this rule.
configs=""
for f in "$BACKENDS_DIR"/*; do
  [ -f "$f" ] || continue
  case "${f##*/}" in _*) continue ;; esac
  configs="$configs $f"
done

if [ -z "$configs" ]; then
  log "FATAL: no backend config files in $BACKENDS_DIR"
  exit 1
fi

run_backend() {
  cfg="$1"
  # The filename IS the backend name: it is the ConfigMap key and the Service port name too.
  name="${cfg##*/}"
  child=""

  # Installed ONCE, covering the whole life of this loop -- including the sleep between restarts.
  # `child` is expanded when the trap FIRES, so it always names the current process.
  #
  # This kills the child directly rather than signalling the process group. `child` IS the
  # wstunnel process, because the subshell below execs into it. An earlier design used `kill 0`,
  # which does reach grandchildren but also signals dumb-init and anything else sharing the
  # group -- imprecise, and untestable outside a container.
  trap 'if [ -n "$child" ]; then kill "$child" 2>/dev/null; fi; exit 0' TERM INT

  while :; do
    (
      # Sourced in a SUBSHELL so a malformed file kills only this iteration, not the supervisor.
      . "$cfg" || exit 66
      : "${TUNNEL_HOST:?TUNNEL_HOST not set}"
      : "${TUNNEL_PREFIX:?TUNNEL_PREFIX not set}"
      : "${TUNNEL_USER:?TUNNEL_USER not set}"
      : "${TUNNEL_PASS:?TUNNEL_PASS not set}"
      : "${TUNNEL_DEST:?TUNNEL_DEST not set}"
      : "${TUNNEL_LOCAL_PORT:?TUNNEL_LOCAL_PORT not set}"

      # TUNNEL_PREFIX is deliberately NOT logged: it is a shared secret and logs are shipped and
      # retained. Read it on demand instead:
      #   kubectl exec ... -- cat /etc/tunnel/backends/<name>
      log "$name: connecting wss://${TUNNEL_HOST} -> 0.0.0.0:${TUNNEL_LOCAL_PORT} -> ${TUNNEL_DEST}"

      # The ONLY value passed via the environment. wstunnel reads this natively and it is a shared
      # secret, so it stays out of argv (and out of `ps`). There is no equivalent for
      # --http-upgrade-credentials, so the password does reach argv -- the same documented leak as
      # scripts/connect.sh.
      export WSTUNNEL_HTTP_UPGRADE_PATH_PREFIX="$TUNNEL_PREFIX"

      # 0.0.0.0, NOT 127.0.0.1. kube-proxy delivers a NodePort to <podIP>:<targetPort>, and a
      # socket bound to loopback is not reachable at the pod IP -- the Service would resolve to a
      # port nothing is listening on. connect.sh binds loopback because it runs on a laptop.
      exec "$WSTUNNEL_BIN" client \
        -L "tcp://0.0.0.0:${TUNNEL_LOCAL_PORT}:${TUNNEL_DEST}" \
        --http-upgrade-credentials "${TUNNEL_USER}:${TUNNEL_PASS}" \
        "wss://${TUNNEL_HOST}"
    ) &
    child=$!

    wait "$child"
    rc=$?

    case "$rc" in
      66|2) log "$name: CONFIG ERROR (rc=$rc) -- check $cfg; retrying in ${RESTART_DELAY}s" ;;
      0)    log "$name: wstunnel exited cleanly; retrying in ${RESTART_DELAY}s" ;;
      *)    log "$name: wstunnel exited rc=$rc; retrying in ${RESTART_DELAY}s" ;;
    esac
    sleep "$RESTART_DELAY"
  done
}

# Installed before any loop starts, so a TERM during startup is still handled.
loop_pids=""
trap 'log "stopping all tunnels"; for p in $loop_pids; do kill "$p" 2>/dev/null; done; wait; exit 0' TERM INT

for cfg in $configs; do
  log "starting backend ${cfg##*/}"
  run_backend "$cfg" &
  loop_pids="$loop_pids $!"
done

wait
log "FATAL: every backend loop exited -- this should be unreachable"
exit 1
