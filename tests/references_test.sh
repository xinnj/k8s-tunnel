#!/bin/sh
# Repo-wide reference hygiene: every scripts/*.sh this repo mentions must actually exist.
#
# This suite exists because of a concrete rot. `scripts/get-credentials.sh` read the tunnel's
# credentials out of the cluster, but the people who need those values are the ones who cannot
# reach the cluster -- that is what the tunnel is for. So the file went, and ten references to it
# across README, a chart's NOTES.txt and the suites went stale with it.
#
# The chart suite did not catch that, and could not: it asserted the string `get-credentials.sh`
# was PRESENT in the install output. Present is not the same as reachable. A test that pins a
# filename is blind to whether that filename resolves to anything, which is exactly the failure
# mode worth guarding.
#
# So this checks the general property instead, over the whole tree, rather than pinning one name.

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
. "$HERE/lib.sh"

# Paths this repo has deliberately removed. They must not be here, and nothing may reference them.
REMOVED="scripts/get-credentials.sh"

# The file that names the above on purpose. Scanning it would report the checker itself.
SELF="tests/references_test.sh"

# Every distinct scripts/<name>.sh referenced anywhere in the tree.
#
# The leading group is load-bearing: it requires `scripts/` to begin a path component. Without it
# the container image's own /etc/tunnel/scripts/_supervisor.sh -- an absolute path inside the pod,
# nothing to do with this repo -- matches mid-path and gets reported as a missing file. With it,
# `scripts/x.sh`, `./scripts/x.sh` and `$(pwd)/scripts/x.sh` are all still found.
scan() {
  find "$ROOT" -type d \( -name .git -o -name .idea \) -prune -o -type f -print |
    while IFS= read -r f; do
      [ "$f" = "$ROOT/$SELF" ] && continue
      grep -oIE '(^|[^A-Za-z0-9._/-])(\./)?scripts/[A-Za-z0-9._-]+\.sh' "$f" 2>/dev/null |
        sed -E 's|^.*(scripts/)|\1|'
    done | sort -u
}

# --- scenarios ---------------------------------------------------------------

scenario_scan_is_live() {
  case_start "the scan actually finds references"

  refs=$(scan)

  # Without this, a broken `find` or a mistyped pattern yields an empty list, every assertion
  # below loops zero times, and the suite reports green while checking nothing at all.
  if printf '%s\n' "$refs" | grep -qxF 'scripts/connect.sh'; then
    pass "the scan finds scripts/connect.sh, so it is really reading the tree"
  else
    fail "the scan finds scripts/connect.sh, so it is really reading the tree" \
      "found: $(printf '%s' "$refs" | tr '\n' ' ')"
  fi
}

scenario_removed_are_gone() {
  case_start "the scripts this repo removed are gone"

  for p in $REMOVED; do
    assert_missing "removed: $p" "$ROOT/$p"
  done

  # And nothing may still point at them. Asserted here as well as below so the failure names the
  # specific file rather than appearing as a generic unresolved reference.
  for p in $REMOVED; do
    hits=$(scan | grep -F -- "$p" || true)
    if [ -z "$hits" ]; then
      pass "nothing references $p"
    else
      fail "nothing references $p" "still mentioned as: $(printf '%s' "$hits" | tr '\n' ' ')"
    fi
  done
}

scenario_every_reference_resolves() {
  case_start "every referenced script exists"

  missing=0
  for ref in $(scan); do
    if [ -e "$ROOT/$ref" ]; then
      pass "$ref exists"
    else
      missing=$((missing + 1))
      fail "$ref exists" "referenced somewhere in the tree, but there is no such file"
    fi
  done
}

# --- run ---------------------------------------------------------------------

suite "references"
scenario_scan_is_live
scenario_removed_are_gone
scenario_every_reference_resolves
summary "references"
