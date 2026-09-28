#!/bin/sh
# Stand-in for the real wstunnel binary, used by tests/supervisor_test.sh.
#
# The supervisor is driven through WSTUNNEL_BIN, so pointing that at this file lets the test read
# exactly what the supervisor passed -- argv, and the one environment variable it sets -- without a
# container, a cluster, or an open port. This stub never listens on anything.
#
# STUB_LOG    required; appends a record of every invocation
# STUB_SLEEP  seconds to stay alive (default 5). The supervisor sits in `wait` for it.
# STUB_EXIT   status to exit with (default 0)

# Several stubs run concurrently and append to one log, so the whole record is built up first and
# emitted with a SINGLE printf. Multiple printfs interleave mid-line between processes, which
# corrupts exactly the argv assertions this stub exists to support.
argv="ARGV"
for a in "$@"; do argv="$argv [$a]"; done

printf '%s PREFIX=[%s] PID=[%s]\n' \
  "$argv" \
  "${WSTUNNEL_HTTP_UPGRADE_PATH_PREFIX:-<unset>}" \
  "$$" >>"${STUB_LOG:?STUB_LOG not set}"

sleep "${STUB_SLEEP:-5}"
exit "${STUB_EXIT:-0}"
