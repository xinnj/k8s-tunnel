#!/bin/sh
# Tests for scripts/lib-kubeconfig.sh, scripts/connect.sh and scripts/front-kubeconfig.sh.
#
# Runs with a stubbed kubectl and a stubbed wstunnel, so it needs no cluster and no real
# credentials. The point is the NAMING and the SERVER URL: a kubeconfig's cluster name cannot be
# renamed after the fact, and two files declaring the same cluster name with different servers in
# one ~/.kube is the collision the original code documents as unfixable.
#
# Each scenario points HOME at a scratch directory so the tests exercise the DEFAULT output path
# (~/.kube/<name>.yaml), not an override. The naming is the thing under test, so the test must not
# be the one choosing the name.

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
. "$HERE/lib.sh"

TMPDIRS=""
cleanup_all() {
  for d in $TMPDIRS; do rm -rf "$d"; done
}
trap cleanup_all EXIT INT TERM

new_tmp() {
  _d=$(mktemp -d)
  TMPDIRS="$TMPDIRS $_d"
  printf '%s' "$_d"
}

# A PATH containing only the stub kubectl, plus the real utilities the scripts need.
make_stub_bin() { # dir
  mkdir -p "$1"
  cp "$HERE/stub-kubectl.sh" "$1/kubectl"
  chmod +x "$1/kubectl"
  printf '%s' "$1"
}

# --- scenarios ---------------------------------------------------------------

scenario_front() {
  case_start "front-kubeconfig.sh points at the NodePort and names it -svc-tunnel"
  d=$(new_tmp); bin=$(make_stub_bin "$d/bin"); mkdir -p "$d/home"
  : >"$d/log"

  out=$(env PATH="$bin:$PATH" KUBECTL_LOG="$d/log" \
    SOURCE_KUBECONFIG="$d/source.config" \
    HOME="$d/home" \
    FRONT_NODE_IP=10.0.0.5 \
    BACKEND=test \
    "$ROOT/scripts/front-kubeconfig.sh" 2>&1)

  assert_file_contains "the backend name is resolved to its nodePort" \
    "$d/log" "--server=https://10.0.0.5:30643"
  assert_file_contains "the cluster/context name carries the -svc-tunnel suffix" \
    "$d/log" "set-cluster test-svc-tunnel"
  assert_file_contains "tls-server-name is preserved" \
    "$d/log" "set clusters.test-svc-tunnel.tls-server-name kubernetes.default.svc"
  # The whole reason for raw TCP: kubectl must still verify against the BACKEND's own name.
  assert_exists "the kubeconfig lands at the default path under the expected name" \
    "$d/home/.kube/test-svc-tunnel.yaml"
  assert_contains "the suffix is explained in the output" "test-svc-tunnel" "$out"
}

scenario_connect() {
  case_start "connect.sh still points at loopback and names it -tunnel"
  d=$(new_tmp); bin=$(make_stub_bin "$d/bin"); mkdir -p "$d/home"
  : >"$d/log"

  env PATH="$bin:$PATH" KUBECTL_LOG="$d/log" \
    SOURCE_KUBECONFIG="$d/source.config" \
    HOME="$d/home" \
    TUNNEL_HOST=test.test.com \
    TUNNEL_PREFIX=alpha \
    TUNNEL_USER=tunnel \
    TUNNEL_PASS=secret \
    WSTUNNEL=/usr/bin/true \
    "$ROOT/scripts/connect.sh" --write-kubeconfig >/dev/null 2>&1

  assert_file_contains "connect.sh still targets loopback" \
    "$d/log" "--server=https://127.0.0.1:6443"
  assert_file_contains "connect.sh still names it -tunnel" \
    "$d/log" "set-cluster test-tunnel"
  assert_exists "connect.sh's kubeconfig keeps its own name" "$d/home/.kube/test-tunnel.yaml"
}

scenario_no_collision() {
  case_start "the two flows cannot collide in one sync folder"
  d=$(new_tmp); bin=$(make_stub_bin "$d/bin"); mkdir -p "$d/home"

  env PATH="$bin:$PATH" KUBECTL_LOG="$d/log-a" \
    SOURCE_KUBECONFIG="$d/source.config" HOME="$d/home" \
    FULL=1 FRONT_NODE_IP=10.0.0.5 BACKEND=test \
    "$ROOT/scripts/front-kubeconfig.sh" >/dev/null 2>&1

  env PATH="$bin:$PATH" KUBECTL_LOG="$d/log-b" \
    SOURCE_KUBECONFIG="$d/source.config" HOME="$d/home" \
    TUNNEL_HOST=h.example.cn TUNNEL_PREFIX=a TUNNEL_USER=u TUNNEL_PASS=p \
    WSTUNNEL=/usr/bin/true \
    "$ROOT/scripts/connect.sh" --write-kubeconfig >/dev/null 2>&1

  assert_exists "both files exist side by side" "$d/home/.kube/test-svc-tunnel.yaml"
  assert_exists "connect.sh's file did not overwrite it" "$d/home/.kube/test-tunnel.yaml"

  # Two distinct files, so the cluster names inside them must differ too.
  n1=$(sed -n 's/.*set-cluster \([^ ]*\).*/\1/p' "$d/log-a" | head -n 1)
  n2=$(sed -n 's/.*set-cluster \([^ ]*\).*/\1/p' "$d/log-b" | head -n 1)
  if [ "$n1" != "$n2" ]; then
    pass "the two cluster names differ ($n1 vs $n2)"
  else
    fail "the two cluster names differ" "both used $n1 -- they would collide in a synced folder"
  fi
}

scenario_unknown_backend() {
  case_start "an unknown backend is refused, and the known ones are listed"
  d=$(new_tmp); bin=$(make_stub_bin "$d/bin")
  : >"$d/log"

  # This stub returns no nodePort for any name, and lists only test -- enough to exercise the
  # guard that fires when BACKEND names a port the Service does not have.
  out=$(env PATH="$bin:$PATH" KUBECTL_LOG="$d/log" \
    SOURCE_KUBECONFIG="$d/source.config" FRONT_NODE_IP=10.0.0.5 BACKEND=typo \
    FAKE_NODE_PORT= FAKE_PORT_NAMES=test \
    "$ROOT/scripts/front-kubeconfig.sh" 2>&1)
  rc=$?

  assert_eq "an unknown backend exits nonzero" "1" "$rc"
  assert_contains "the error names the backend" "typo" "$out"
  assert_contains "the error lists the known backends" "test" "$out"
  assert_contains "the error says how to fix it" "values.yaml" "$out"
}

# --- run ---------------------------------------------------------------------

suite "kubeconfig"
for s in "$ROOT/scripts/connect.sh" "$ROOT/scripts/front-kubeconfig.sh" "$ROOT/scripts/lib-kubeconfig.sh"; do
  if [ ! -f "$s" ]; then
    fail "script exists" "$s is missing"
    summary "kubeconfig"
    exit 1
  fi
done

# The stubs assume nodePort 30643 for backend test, matching the chart test fixture. If that
# drifts, this suite would silently test nothing -- so pin the assumption here.
if grep -qF 'nodePort: 30643' "$HERE/fixtures/values-two-backends.yaml"; then
  pass "the fixture still pins test to nodePort 30643"
else
  fail "the fixture still pins test to nodePort 30643" \
    "this suite hardcodes 30643; update it with the fixture"
fi

scenario_front
scenario_connect
scenario_no_collision
scenario_unknown_backend
summary "kubeconfig"
