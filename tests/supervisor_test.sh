#!/bin/sh
# Unit tests for charts/k8s-tunnel-client/files/supervisor.sh.
#
# Runs on the host with no container, no cluster and no open ports -- the stub never listens. The
# supervisor is driven entirely through the env overrides it exposes for this purpose
# (WSTUNNEL_BIN, BACKENDS_DIR, RESTART_DELAY), which is the only reason those are overridable.
#
# The config files here are written as LITERAL BYTES via quoted heredocs, so this suite tests the
# supervisor's handling of already-correct input. Producing correctly-quoted input is the chart's
# job and is asserted separately in chart_test.sh.
#
# Usage: supervisor_test.sh [dash|sh]

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
SUPERVISOR="$ROOT/charts/k8s-tunnel-client/files/supervisor.sh"
STUB="$HERE/stub-wstunnel.sh"
. "$HERE/lib.sh"

SH_UNDER_TEST="${1:-dash}"

# The values the config files below must source into. Hostile on purpose:
#   $$ -> the shell's PID if the quoting is wrong
#   '  -> needs the '\'' idiom to survive single-quoting
#   \  -> must not be eaten as an escape
PW1="p@\$\$w0rd'x\\y"
PW2="s3cr3t\\'q\$"

TMPDIRS=""
cleanup_all() {
  for d in $TMPDIRS; do
    for p in $(sed -n 's/.*PID=\[\([0-9]*\)\].*/\1/p' "$d/stub.log" 2>/dev/null); do
      kill -9 "$p" 2>/dev/null
    done
    rm -rf "$d"
  done
}
trap cleanup_all EXIT INT TERM

new_tmp() {
  _d=$(mktemp -d)
  TMPDIRS="$TMPDIRS $_d"
  printf '%s' "$_d"
}

# Two backends, exactly as the chart would render them.
write_two_backends() {
  mkdir -p "$1"
  cat >"$1/test" <<'EOF'
TUNNEL_HOST='test.test.com'
TUNNEL_PREFIX='alpha$prefix'
TUNNEL_USER='tunnel'
TUNNEL_PASS='p@$$w0rd'\''x\y'
TUNNEL_DEST='kubernetes.default.svc:443'
TUNNEL_LOCAL_PORT='6443'
EOF
  cat >"$1/test-prod" <<'EOF'
TUNNEL_HOST='test-prod.test.com'
TUNNEL_PREFIX='beta$prefix'
TUNNEL_USER='tunnel'
TUNNEL_PASS='s3cr3t\'\''q$'
TUNNEL_DEST='kubernetes.default.svc:443'
TUNNEL_LOCAL_PORT='6444'
EOF
}

start_supervisor() { # dir  [env...]
  _d="$1"; shift
  env STUB_LOG="$_d/stub.log" WSTUNNEL_BIN="$STUB" BACKENDS_DIR="$_d/backends" \
    "$@" "$SH_UNDER_TEST" "$SUPERVISOR" >"$_d/sup.log" 2>&1 &
  printf '%s' "$!"
}

# --- scenarios ---------------------------------------------------------------

scenario_argv() {
  case_start "one process per backend, with the right argv"
  d=$(new_tmp); : >"$d/stub.log"; write_two_backends "$d/backends"

  sup=$(start_supervisor "$d" STUB_SLEEP=5 RESTART_DELAY=1)

  if wait_for_matches "$d/stub.log" 'ARGV' 2 8; then
    assert_eq "two backends start two wstunnel processes" "2" "$(count_matches "$d/stub.log" 'ARGV')"
  else
    fail "two backends start two wstunnel processes" \
      "$(count_matches "$d/stub.log" 'ARGV') invocation(s); supervisor log: $(tail -n 5 "$d/sup.log" | tr '\n' ' ')"
  fi

  l1=$(grep -F 'wss://test.test.com' "$d/stub.log" | head -n 1)
  l2=$(grep -F 'wss://test-prod.test.com' "$d/stub.log" | head -n 1)

  assert_contains "backend 1 dials its own host" "[wss://test.test.com]" "$l1"
  assert_contains "backend 2 dials its own host" "[wss://test-prod.test.com]" "$l2"

  # The whole NodePort design rests on this binding a wildcard address. A loopback bind would
  # leave the Service pointing at a port nothing answers on.
  assert_contains "backend 1 binds 0.0.0.0" \
    "[-L] [tcp://0.0.0.0:6443:kubernetes.default.svc:443]" "$l1"
  assert_contains "backend 2 binds 0.0.0.0" \
    "[-L] [tcp://0.0.0.0:6444:kubernetes.default.svc:443]" "$l2"
  assert_file_not_contains "no invocation binds loopback" "$d/stub.log" 'tcp://127.0.0.1'

  assert_contains "backend 1 password arrives byte-identical" \
    "[--http-upgrade-credentials] [tunnel:$PW1]" "$l1"
  assert_contains "backend 2 password arrives byte-identical" \
    "[--http-upgrade-credentials] [tunnel:$PW2]" "$l2"

  assert_file_contains "prefix reaches the child via the environment" "$d/stub.log" "PREFIX=[alpha\$prefix]"
  assert_file_contains "second backend's prefix too" "$d/stub.log" "PREFIX=[beta\$prefix]"

  # The prefix is a shared secret and logs get shipped.
  assert_file_not_contains "the prefix is never logged by the supervisor" "$d/sup.log" 'alpha$prefix'

  kill -TERM "$sup" 2>/dev/null

  # Must find at least one pid, or the assertion below silently does not run.
  pids=$(sed -n 's/.*PID=\[\([0-9]*\)\].*/\1/p' "$d/stub.log")
  if [ -z "$pids" ]; then
    fail "TERM stops the wstunnel children" "no PID= records in the stub log to check"
  fi
  for p in $pids; do
    if wait_for_gone "$p" 3; then
      pass "TERM stops wstunnel pid $p"
    else
      fail "TERM stops wstunnel pid $p" "process still alive after 3s"
    fi
  done
  if wait_for_gone "$sup" 3; then
    pass "TERM stops the supervisor"
  else
    fail "TERM stops the supervisor" "still alive after 3s"
  fi
}

scenario_restart() {
  case_start "a dying tunnel is restarted"
  d=$(new_tmp); : >"$d/stub.log"; write_two_backends "$d/backends"

  sup=$(start_supervisor "$d" STUB_SLEEP=0 STUB_EXIT=3 RESTART_DELAY=1)
  wait_for_matches "$d/stub.log" 'ARGV' 3 8
  n=$(count_matches "$d/stub.log" 'ARGV')
  if [ "$n" -ge 3 ]; then
    pass "the loop restarts a tunnel that exits (saw $n starts)"
  else
    fail "the loop restarts a tunnel that exits" "saw only $n starts in 8s"
  fi
  assert_file_contains "the exit status is reported" "$d/sup.log" 'rc=3'

  kill -TERM "$sup" 2>/dev/null
}

scenario_isolation() {
  case_start "one malformed backend does not take down the others"
  d=$(new_tmp); : >"$d/stub.log"; write_two_backends "$d/backends"
  cat >"$d/backends/broken" <<'EOF'
TUNNEL_HOST='broken.example.cn'
this is not valid shell ( ( (
EOF

  sup=$(start_supervisor "$d" STUB_SLEEP=5 RESTART_DELAY=1)

  if wait_for_matches "$d/stub.log" 'wss://test.test.com' 1 8; then
    pass "the healthy backend still starts alongside a malformed one"
  else
    fail "the healthy backend still starts alongside a malformed one" \
      "$(tail -n 5 "$d/sup.log" | tr '\n' ' ')"
  fi
  assert_file_contains "the malformed backend is named and flagged" "$d/sup.log" 'broken'
  assert_file_contains "the malformed backend is a config error" "$d/sup.log" 'CONFIG ERROR'
  assert_file_not_contains "the malformed backend never reaches wstunnel" "$d/stub.log" 'broken.example.cn'

  kill -TERM "$sup" 2>/dev/null
}

scenario_bad_mount() {
  case_start "a missing or empty config mount is fatal and loud"
  d=$(new_tmp); : >"$d/stub.log"

  out=$(env STUB_LOG="$d/stub.log" WSTUNNEL_BIN="$STUB" BACKENDS_DIR="$d/does-not-exist" \
    "$SH_UNDER_TEST" "$SUPERVISOR" 2>&1)
  assert_eq "missing BACKENDS_DIR exits 1" "1" "$?"
  assert_contains "missing BACKENDS_DIR says FATAL" "FATAL" "$out"

  mkdir -p "$d/empty"
  out=$(env STUB_LOG="$d/stub.log" WSTUNNEL_BIN="$STUB" BACKENDS_DIR="$d/empty" \
    "$SH_UNDER_TEST" "$SUPERVISOR" 2>&1)
  assert_eq "empty BACKENDS_DIR exits 1" "1" "$?"
  assert_contains "empty BACKENDS_DIR says FATAL" "FATAL" "$out"

  # A pod that runs with zero tunnels while looking healthy is the failure this prevents.
  assert_eq "no tunnel was started" "0" "$(count_matches "$d/stub.log" 'ARGV')"
}

scenario_syntax() {
  case_start "the supervisor is valid POSIX sh"
  d=$(new_tmp)
  if "$SH_UNDER_TEST" -n "$SUPERVISOR" 2>"$d/syntax.err"; then
    pass "$SH_UNDER_TEST -n accepts the supervisor"
  else
    fail "$SH_UNDER_TEST -n accepts the supervisor" "$(cat "$d/syntax.err")"
  fi
}

# --- run --------------------------------------------------------------------

suite "supervisor [$SH_UNDER_TEST]"
if [ ! -f "$SUPERVISOR" ]; then
  fail "supervisor exists" "$SUPERVISOR is missing"
  summary "supervisor [$SH_UNDER_TEST]"
  exit 1
fi
scenario_syntax
scenario_argv
scenario_restart
scenario_isolation
scenario_bad_mount
summary "supervisor [$SH_UNDER_TEST]"
