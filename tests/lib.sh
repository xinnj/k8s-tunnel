# shellcheck shell=sh
# Shared helpers for the k8s-tunnel test suites.
#
# POSIX sh only. The suites are run under dash as well as sh, because dash is the /bin/sh the
# container actually uses. macOS /bin/sh is bash 3.2 in sh-mode, so it happily accepts bashisms
# that fail in the image -- running under dash is what catches those.

PASSED=0
FAILED=0

# --- reporting ---------------------------------------------------------------

suite() {
  printf '\n=== %s ===\n' "$1"
}

case_start() {
  printf '\n# %s\n' "$1"
}

pass() {
  PASSED=$((PASSED + 1))
  printf 'ok      - %s\n' "$1"
}

fail() {
  FAILED=$((FAILED + 1))
  printf 'NOT OK  - %s\n' "$1"
  if [ -n "${2:-}" ]; then
    printf '          %s\n' "$2"
  fi
}

summary() {
  printf '\n--- %s: %s passed, %s failed ---\n' "$1" "$PASSED" "$FAILED"
  [ "$FAILED" -eq 0 ]
}

# --- assertions --------------------------------------------------------------

assert_eq() { # label expected actual
  if [ "$2" = "$3" ]; then
    pass "$1"
  else
    fail "$1" "expected [$2], got [$3]"
  fi
}

assert_contains() { # label needle haystack
  case "$3" in
    *"$2"*) pass "$1" ;;
    *) fail "$1" "expected to contain [$2]; got [$3]" ;;
  esac
}

assert_not_contains() { # label needle haystack
  case "$3" in
    *"$2"*) fail "$1" "expected NOT to contain [$2]; got [$3]" ;;
    *) pass "$1" ;;
  esac
}

assert_file_contains() { # label file needle
  if grep -qF -- "$3" "$2" 2>/dev/null; then
    pass "$1"
  else
    fail "$1" "[$3] not found in $2"
  fi
}

assert_file_not_contains() { # label file needle
  if grep -qF -- "$3" "$2" 2>/dev/null; then
    fail "$1" "[$3] unexpectedly found in $2"
  else
    pass "$1"
  fi
}

# assert_file_matches <label> <file> <extended-regex>
#
# For "this line has a VALUE" rather than "this line exists". Helm renders a missing map key as an
# EMPTY string, not `<no value>` (it compiles templates with missingkey=zero), so asserting that a
# label is absent proves nothing -- a stale field renders as "label<space>" and looks fine.
assert_file_matches() { # label file ere
  if grep -qE -- "$3" "$2" 2>/dev/null; then
    pass "$1"
  else
    fail "$1" "no line in $2 matches /$3/"
  fi
}

assert_file_eq() { # label file-a file-b
  if cmp -s "$2" "$3"; then
    pass "$1"
  else
    fail "$1" "$2 and $3 differ"
  fi
}

assert_exists() { # label path
  if [ -e "$2" ]; then pass "$1"; else fail "$1" "$2 does not exist"; fi
}

assert_missing() { # label path
  if [ -e "$2" ]; then fail "$1" "$2 should not exist"; else pass "$1"; fi
}

# expect_fail <label> <stderr-fragment> <command...>
# Asserts the command exits nonzero AND says why. A guard that fails silently is no guard.
expect_fail() {
  _label="$1"; _frag="$2"; shift 2
  _out=$("$@" 2>&1)
  _rc=$?
  if [ "$_rc" -eq 0 ]; then
    fail "$_label" "expected a nonzero exit, got 0"
    return
  fi
  case "$_out" in
    *"$_frag"*) pass "$_label" ;;
    *)
      fail "$_label" "exit=$_rc but the message lacks [$_frag]; got: $(printf '%s' "$_out" | head -n 2 | tr '\n' ' ')"
      ;;
  esac
}

# --- polling -----------------------------------------------------------------

# wait_for <timeout-seconds> <command...>
wait_for() {
  _t="$1"; shift
  _n=0
  while [ "$_n" -lt $((_t * 10)) ]; do
    if "$@" >/dev/null 2>&1; then return 0; fi
    sleep 0.1
    _n=$((_n + 1))
  done
  return 1
}

# count_matches <file> <fixed-string>
count_matches() {
  _c=$(grep -cF -- "$2" "$1" 2>/dev/null)
  [ -n "$_c" ] || _c=0
  printf '%s' "$_c"
}

# wait_for_matches <file> <fixed-string> <count> <timeout-seconds>
wait_for_matches() {
  _n=0
  while [ "$_n" -lt $(($4 * 10)) ]; do
    if [ "$(count_matches "$1" "$2")" -ge "$3" ]; then return 0; fi
    sleep 0.1
    _n=$((_n + 1))
  done
  return 1
}

# wait_for_gone <pid> <timeout-seconds>  -- true once the pid no longer exists
wait_for_gone() {
  _n=0
  while [ "$_n" -lt $(($2 * 10)) ]; do
    if ! kill -0 "$1" 2>/dev/null; then return 0; fi
    sleep 0.1
    _n=$((_n + 1))
  done
  return 1
}
