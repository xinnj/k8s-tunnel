#!/bin/sh
# Stub kubectl, for testing the kubeconfig builders without a cluster.
#
# Records every invocation, then answers the handful of `config view` / `config current-context`
# queries the builders make. It does not write a real kubeconfig -- it only ensures the file named
# by --kubeconfig exists, so the `install` that publishes it has something to copy.
#
# KUBECTL_LOG   required; appends every invocation's argv
# FAKE_CTX      source kubeconfig's current-context   (default test)
# FAKE_USER     the user bound to that context        (default kubernetes-admin)
# FAKE_CA       what kube-root-ca.crt returns         (default FAKECA)
# FAKE_REACHABLE exit status for the final reachability probe (default 0)

printf '%s\n' "$*" >>"${KUBECTL_LOG:?KUBECTL_LOG not set}"

args="$*"

# Locate the --kubeconfig target, if any.
kcfg=""
prev=""
for a in "$@"; do
  if [ "$prev" = "--kubeconfig" ]; then kcfg="$a"; fi
  prev="$a"
done

case "$args" in
  *"config current-context"*) printf '%s' "${FAKE_CTX:-test}" ;;
  # Covers both the contexts[...] and users[...] jsonpath shapes used for identity lookups.
  *"contexts[?(@.name="*) printf '%s' "${FAKE_USER:-kubernetes-admin}" ;;
  *"client-certificate-data"*) printf '%s' "$(printf 'FAKECERT' | base64)" ;;
  *"client-key-data"*) printf '%s' "$(printf 'FAKEKEY' | base64)" ;;
  *kube-root-ca.crt*) printf '%s' "${FAKE_CA:-FAKECA}" ;;
  # The front Service lookup, and the "known backends" listing that follows a miss.
  # `${VAR-default}` not `${VAR:-default}`: these must be able to be set to EMPTY to simulate a
  # backend whose port is absent.
  *"get svc"*nodePort*) printf '%s' "${FAKE_NODE_PORT-30643}" ;;
  *"get svc"*) printf '%s' "${FAKE_PORT_NAMES-test}" ;;
  *"get namespaces"*) exit "${FAKE_REACHABLE:-0}" ;;
  *)
    if [ -n "$kcfg" ]; then : >>"$kcfg"; fi
    ;;
esac
exit 0
