#!/bin/sh
# Test entry point for the k8s-tunnel charts.
#
# Runs the supervisor unit tests under BOTH dash and sh, then the chart rendering tests.
#
# dash comes first on purpose: it is the /bin/sh the container actually uses. macOS /bin/sh is
# bash 3.2 in sh-mode and accepts bashisms that fail in the image, so passing under sh proves
# very little on its own.

set -u
HERE=$(cd "$(dirname "$0")" && pwd)

# Missing tools are a hard failure, never a skip: a suite that quietly does not run is how a
# broken chart ships.
missing=""
for t in helm yq; do
  if ! command -v "$t" >/dev/null 2>&1; then
    missing="$missing $t"
  fi
done
if [ -n "$missing" ]; then
  printf 'FATAL: missing required tool(s):%s\n' "$missing" >&2
  printf '\n' >&2
  printf '  yq   -> brew install yq\n' >&2
  printf '          If brew has no bottle for your platform (it falls back to building from\n' >&2
  printf '          source plus a Go upgrade), use the release binary instead:\n' >&2
  printf '            curl -fsSL -o /tmp/yq \\\n' >&2
  printf '              https://github.com/mikefarah/yq/releases/download/v4.53.6/yq_darwin_arm64\n' >&2
  printf '            install -m 0755 /tmp/yq "\$HOME/.local/bin/yq"\n' >&2
  printf '  helm -> https://helm.sh/docs/intro/install/\n' >&2
  exit 2
fi

SUITES=0
FAILED=0

run_suite() { # label shell script [args...]
  _label="$1"; shift
  SUITES=$((SUITES + 1))
  if "$@"; then
    printf '\n>>> suite passed: %s\n' "$_label"
  else
    printf '\n>>> suite FAILED: %s\n' "$_label"
    FAILED=$((FAILED + 1))
  fi
}

for s in dash sh; do
  if command -v "$s" >/dev/null 2>&1; then
    run_suite "supervisor[$s]" "$s" "$HERE/supervisor_test.sh" "$s"
  else
    printf '\n>>> skipping supervisor[%s]: not installed\n' "$s"
  fi
done

if [ -f "$HERE/server_chart_test.sh" ]; then
  run_suite "server-chart" /bin/sh "$HERE/server_chart_test.sh"
fi

if [ -f "$HERE/chart_test.sh" ]; then
  run_suite "chart" /bin/sh "$HERE/chart_test.sh"
fi

if [ -f "$HERE/kubeconfig_test.sh" ]; then
  run_suite "kubeconfig" /bin/sh "$HERE/kubeconfig_test.sh"
fi

if [ -f "$HERE/references_test.sh" ]; then
  run_suite "references" /bin/sh "$HERE/references_test.sh"
fi

printf '\n===============================\n'
printf '%s suite(s), %s failed\n' "$SUITES" "$FAILED"
[ "$FAILED" -eq 0 ] || exit 1
printf 'ALL GREEN\n'
