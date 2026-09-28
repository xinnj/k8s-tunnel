#!/bin/sh
# Rendering tests for charts/k8s-tunnel-client.
#
# Everything here is a claim the chart README and the spec make, checked against `helm template`
# output rather than against the templates by eye. The structural assertions matter most: a chart
# can render happily and still hand raw TCP to a backend API server, leak the password into the
# pod spec, or point a NodePort at a port nothing listens on.
#
# Guard cases mutate the good fixture with sed rather than using `helm --set`, so they do not
# depend on Helm's list-merge semantics for `backends[]`.

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
CHART="$ROOT/charts/k8s-tunnel-client"
FIXTURE="$HERE/fixtures/values-two-backends.yaml"
RELEASE="t"
NS="k8s-tunnel-client"

. "$HERE/lib.sh"

# Values as the fixture must render them, exactly. The password exercises the shell-quoting path:
# unquoted, `$$` expands to the shell's pid and `'` terminates the string.
PW1="p@\$\$w0rd'x\\y"
PW2="s3cr3t\\'q\$"
# A distinctive substring of PW1 with no backslash or quote, safe to grep for inside YAML.
PW1_MARKER='p@$$w0rd'

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

render() { # <values-file> [extra helm args...]
  # stderr is deliberately NOT discarded: the guard tests assert on the `fail` message, and an
  # empty message would make every guard look like it passed for the wrong reason.
  _f="$1"; shift
  helm template "$RELEASE" "$CHART" -n "$NS" -f "$_f" "$@"
}

# mutate <sed-expr> -- writes a variant of the good fixture, returns its path
mutate() {
  _d=$(new_tmp)
  sed "$1" "$FIXTURE" >"$_d/values.yaml"
  printf '%s' "$_d/values.yaml"
}

doc() { # <values-file> <kind>
  render "$1" | yq "select(.kind == \"$2\")"
}

# NOTES.txt is rendered by `helm install`, never by `helm template`, so it needs its own accessor.
notes() { # <values-file>
  helm install "$RELEASE" "$CHART" -n "$NS" -f "$1" --dry-run 2>&1 | sed -n '/^NOTES:/,$p'
}

checksum_of() { # <values-file>
  doc "$1" Deployment | yq -r '.spec.template.metadata.annotations["checksum/config"]'
}

# --- structural --------------------------------------------------------------

scenario_shape() {
  case_start "renders exactly a ConfigMap, a Deployment and a Service"
  d=$(new_tmp); render "$FIXTURE" >"$d/all.yaml"

  # yq emits `---` between documents of a multi-doc stream; keep only real kinds.
  got=$(yq -r '.kind' "$d/all.yaml" | grep -E '^[A-Z]' | sort | tr '\n' ' ')
  assert_eq "the object set is exactly right" "ConfigMap Deployment Service " "$got"

  # An Ingress here would be a design error: the tunnel carries raw TCP, so an L7 hop would
  # re-originate the TLS that must terminate at the backend API server.
  assert_eq "the Service is a NodePort" "NodePort" \
    "$(doc "$FIXTURE" Service | yq -r '.spec.type')"
  assert_eq "externalTrafficPolicy defaults to Cluster (any node answers)" "Cluster" \
    "$(doc "$FIXTURE" Service | yq -r '.spec.externalTrafficPolicy')"
}

scenario_service_ports() {
  case_start "one Service port per backend, with the pinned nodePort"
  s=$(doc "$FIXTURE" Service)

  assert_eq "one port entry per backend" "2" "$(printf '%s' "$s" | yq -r '.spec.ports | length')"
  assert_eq "port names are unique" "2" \
    "$(printf '%s' "$s" | yq -r '[.spec.ports[].name] | unique | length')"
  # The expectation comes from the fixture and is sorted the same way as the rendered side. Writing
  # the sorted names out by hand made this a test of the fixture's DECLARATION ORDER too: a rename
  # that changes which name sorts first fails it even when the chart is perfectly correct.
  want=$(yq -r '.backends[].name' "$FIXTURE" | sort | tr '\n' ' ' | sed 's/ $//')
  assert_eq "port names are the backend names" "$want" \
    "$(printf '%s' "$s" | yq -r '[.spec.ports[].name] | sort | join(" ")')"

  # port == nodePort, so there is exactly one number per backend: the same value inside the
  # cluster and outside it, and the value that ends up in a consumer's kubeconfig.
  assert_eq "backend 1 port/nodePort/targetPort" "30643 30643 6443" \
    "$(printf '%s' "$s" | yq -r '.spec.ports[] | select(.name == "test") | "\(.port) \(.nodePort) \(.targetPort)"')"
  assert_eq "backend 2 port/nodePort/targetPort" "30644 30644 6444" \
    "$(printf '%s' "$s" | yq -r '.spec.ports[] | select(.name == "test-prod") | "\(.port) \(.nodePort) \(.targetPort)"')"
  assert_eq "protocol is TCP" "TCP" \
    "$(printf '%s' "$s" | yq -r '.spec.ports[0].protocol')"
}

scenario_secrets() {
  case_start "the password never reaches the pod spec"
  d=$(new_tmp)
  doc "$FIXTURE" Deployment >"$d/dep.yaml"
  doc "$FIXTURE" ConfigMap >"$d/cm.yaml"

  # If the password were passed as a container arg the obvious way, it would be here -- readable
  # by anything with get-pod RBAC, and stored in etcd.
  assert_file_not_contains "no password marker in the Deployment" "$d/dep.yaml" "$PW1_MARKER"
  assert_file_not_contains "no password marker in the Deployment (backend 2)" "$d/dep.yaml" 's3cr3t'
  assert_file_not_contains "no TUNNEL_PASS envVar in the Deployment" "$d/dep.yaml" 'TUNNEL_PASS'

  # The prefix is a shared secret, and it stays out of argv via wstunnel's native env var.
  assert_file_not_contains "the prefix is not a container arg" "$d/dep.yaml" 'alpha$prefix'

  # The real assertion: the quoted config, when SOURCED, yields the exact password back.
  for pair in "test:$PW1" "test-prod:$PW2"; do
    name=${pair%%:*}
    want=${pair#*:}
    cfg="$d/cfg-$name"
    yq -r "select(.kind == \"ConfigMap\") | .data[\"$name\"]" "$d/cm.yaml" >"$cfg"
    got=$(
      # shellcheck source=/dev/null
      . "$cfg"
      printf '%s' "$TUNNEL_PASS"
    )
    assert_eq "$name: the sourced config reproduces the password byte for byte" "$want" "$got"
  done

  # A regression to Go's `quote` would use double quotes and re-introduce expansion.
  assert_file_contains "config values are single-quoted" "$d/cfg-test" "TUNNEL_PASS='"
  assert_file_not_contains "config values are not double-quoted" "$d/cfg-test" 'TUNNEL_PASS="'
}

scenario_supervisor_script() {
  case_start "the supervisor ships in the ConfigMap, byte for byte"
  d=$(new_tmp)
  doc "$FIXTURE" ConfigMap | yq -r '.data["_supervisor.sh"]' >"$d/from-cm.sh"

  assert_file_eq "the mounted supervisor matches files/supervisor.sh" \
    "$d/from-cm.sh" "$CHART/files/supervisor.sh"

  no=$(doc "$FIXTURE" ConfigMap | yq -r '.data["test"]')
  assert_contains "a backend config does not look like the supervisor" "TUNNEL_HOST=" "$no"
}

scenario_volumes() {
  case_start "the supervisor is not mounted as a backend"
  dep=$(doc "$FIXTURE" Deployment)

  backends_keys=$(printf '%s' "$dep" |
    yq -r '.spec.template.spec.volumes[] | select(.name == "backends") | .configMap.items[].key' | sort | tr '\n' ' ')
  scripts_keys=$(printf '%s' "$dep" |
    yq -r '.spec.template.spec.volumes[] | select(.name == "scripts") | .configMap.items[].key' | sort | tr '\n' ' ')

  # Without explicit items, the supervisor would be mounted into the backends dir and
  # `.`-sourced as if it were a backend config.
  # Same reasoning as the Service ports above: derived, and sorted on both sides.
  want=$(yq -r '.backends[].name' "$FIXTURE" | sort | tr '\n' ' ')
  assert_eq "the backends volume carries only backend configs" "$want" "$backends_keys"
  assert_eq "the scripts volume carries only the supervisor" "_supervisor.sh " "$scripts_keys"
}

scenario_port_consistency() {
  case_start "the derived listen port agrees across all three templates"
  d=$(new_tmp)
  doc "$FIXTURE" ConfigMap >"$d/cm.yaml"
  doc "$FIXTURE" Deployment >"$d/dep.yaml"
  doc "$FIXTURE" Service >"$d/svc.yaml"

  # The port is computed independently in configmap.yaml, deployment.yaml and service.yaml. If
  # those expressions ever diverge, the pod is Running, the Service has endpoints, and every
  # connection is refused -- with nothing to indicate why.
  for name in test test-prod; do
    cfg=$(yq -r ".data[\"$name\"]" "$d/cm.yaml" | sed -n "s/^TUNNEL_LOCAL_PORT='\(.*\)'\$/\1/p")
    cport=$(yq -r ".spec.template.spec.containers[0].ports[] | select(.name == \"$name\") | .containerPort" "$d/dep.yaml")
    tport=$(yq -r ".spec.ports[] | select(.name == \"$name\") | .targetPort" "$d/svc.yaml")
    assert_eq "$name: what the supervisor binds == containerPort == targetPort" \
      "$cfg" "$(printf '%s' "$cport")"
    assert_eq "$name: targetPort == containerPort" "$cport" "$(printf '%s' "$tport")"
  done
}

scenario_notes() {
  case_start "the install output is a compact block per backend"
  d=$(new_tmp); notes "$FIXTURE" >"$d/notes.txt"

  # name:nodePort:host:prefix
  for pair in \
    "test:30643:test.test.com:alpha" \
    "test-prod:30644:test-prod.test.com:beta"
  do
    name=${pair%%:*}; rest=${pair#*:}
    np=${rest%%:*}; rest=${rest#*:}
    host=${rest%%:*}; pfx=${rest#*:}

    assert_file_matches "$name: host is populated" "$d/notes.txt" "host: +$host"
    assert_file_matches "$name: prefix is populated" "$d/notes.txt" "prefix: +$pfx"
    assert_file_matches "$name: user is populated" "$d/notes.txt" "user: +tunnel"
    assert_file_matches "$name: nodePort is populated" "$d/notes.txt" "nodePort: +$np"
    # A label followed by nothing renders as "label<space>" and looks fine, so assert the value is
    # actually there -- that is how "(dest )" shipped unnoticed once already.
    assert_file_matches "$name: Password is populated" "$d/notes.txt" \
      "Password: +kubectl .*cat /etc/tunnel/backends/$name"
  done

  # This output lands in terminal scrollback and in CI logs.
  assert_file_not_contains "the password is NOT printed" "$d/notes.txt" "$PW1_MARKER"
  assert_file_not_contains "the password is NOT printed (backend 2)" "$d/notes.txt" "s3cr3t"

  # Kept short on purpose -- it was ~45 lines of prose around five values per backend.
  lines=$(grep -c . "$d/notes.txt")
  if [ "$lines" -le 30 ]; then
    pass "the output stays compact for two backends ($lines non-blank lines)"
  else
    fail "the output stays compact for two backends" "$lines non-blank lines"
  fi
}

scenario_notes_cardinality() {
  case_start "the install output holds up for one backend and for many"
  d=$(new_tmp)

  sed '/^  - name: test-prod/,/^    nodePort: 30644/d' "$FIXTURE" >"$d/one.yaml"
  notes "$d/one.yaml" >"$d/one.txt"
  assert_file_contains "one backend is counted correctly" "$d/one.txt" "1 backend(s)"
  assert_file_not_contains "the dropped backend is gone" "$d/one.txt" "test-prod"
  assert_file_matches "the remaining backend is intact" "$d/one.txt" 'host: +test\.test\.com'

  # Five, to prove the per-backend block repeats cleanly rather than only working for two.
  {
    printf 'dest: kubernetes.default.svc:443\nbackends:\n'
    i=0
    while [ "$i" -lt 5 ]; do
      printf '  - name: be-%s\n    host: be-%s.example.cn\n    prefix: p%s\n    user: u\n    password: pw%s\n    nodePort: %s\n' \
        "$i" "$i" "$i" "$i" "$((30640 + i))"
      i=$((i + 1))
    done
  } >"$d/five.yaml"
  notes "$d/five.yaml" >"$d/five.txt"

  assert_file_contains "five backends are counted correctly" "$d/five.txt" "5 backend(s)"
  assert_file_matches "the fifth backend's block is populated" "$d/five.txt" 'host: +be-4\.example\.cn'
  assert_file_matches "the fifth backend's nodePort is shown" "$d/five.txt" 'nodePort: +30644'
  assert_file_matches "the fifth backend's retrieval command names it" "$d/five.txt" \
    'cat /etc/tunnel/backends/be-4'
}

scenario_deployment_hardening() {
  case_start "the pod is hardened the same way as the server chart"
  dep=$(doc "$FIXTURE" Deployment)

  assert_eq "the service account token is not mounted" "false" \
    "$(printf '%s' "$dep" | yq -r '.spec.template.spec.automountServiceAccountToken')"
  # A different uid cannot traverse /home/app (mode 700) to exec the binary: exit 128,
  # StartError, and no logs at all.
  assert_eq "runs as the image's uid:gid" "1000 1000" \
    "$(printf '%s' "$dep" | yq -r '.spec.template.spec.securityContext | "\(.runAsUser) \(.runAsGroup)"')"
  assert_eq "runAsNonRoot" "true" \
    "$(printf '%s' "$dep" | yq -r '.spec.template.spec.securityContext.runAsNonRoot')"
  assert_eq "seccomp is RuntimeDefault" "RuntimeDefault" \
    "$(printf '%s' "$dep" | yq -r '.spec.template.spec.securityContext.seccompProfile.type')"

  c='.spec.template.spec.containers[0]'
  assert_eq "no privilege escalation" "false" "$(printf '%s' "$dep" | yq -r "$c.securityContext.allowPrivilegeEscalation")"
  assert_eq "read-only root filesystem" "true" "$(printf '%s' "$dep" | yq -r "$c.securityContext.readOnlyRootFilesystem")"
  assert_eq "all capabilities dropped" "ALL" "$(printf '%s' "$dep" | yq -r "$c.securityContext.capabilities.drop[0]")"
  assert_eq "one replica" "1" "$(printf '%s' "$dep" | yq -r '.spec.replicas')"

  assert_eq "dumb-init stays PID 1 and runs the supervisor" \
    "/usr/bin/dumb-init -v -- /bin/sh /etc/tunnel/scripts/_supervisor.sh" \
    "$(printf '%s' "$dep" | yq -r "$c.command | join(\" \")")"

  # Nothing in the image can probe TCP (no curl/nc/bash, and dash has no /dev/tcp), and a
  # container gets one liveness and one readiness probe -- so per-backend health cannot be
  # expressed. Pinned so a later "helpful" probe is caught rather than silently misleading.
  assert_eq "no liveness probe" "null" "$(printf '%s' "$dep" | yq -r "$c.livenessProbe")"
  assert_eq "no readiness probe" "null" "$(printf '%s' "$dep" | yq -r "$c.readinessProbe")"

  assert_eq "every backend's local port is declared" "6443 6444" \
    "$(printf '%s' "$dep" | yq -r "[$c.ports[].containerPort] | sort | join(\" \")")"
  assert_eq "no emptyDir is needed" "0" \
    "$(printf '%s' "$dep" | yq -r '[.spec.template.spec.volumes[] | select(has("emptyDir"))] | length')"
}

scenario_checksum() {
  case_start "a config change rolls the pod, and identical config does not"
  d=$(new_tmp)

  c1=$(checksum_of "$FIXTURE")
  c2=$(checksum_of "$FIXTURE")
  assert_eq "the checksum is stable across renders (nothing random in this chart)" "$c1" "$c2"
  assert_eq "the checksum is a sha256" "64" "$(printf '%s' "$c1" | tr -d '\n' | wc -c | tr -d ' ')"

  # A mounted ConfigMap does not rewrite a running process's argv, so without this the pod keeps
  # the old credentials until something else restarts it.
  v=$(mutate "s/p@\\\$\\\$w0rd/rotated/")
  c3=$(checksum_of "$v")
  if [ "$c1" != "$c3" ]; then
    pass "rotating a password changes the checksum, so a rollout is triggered"
  else
    fail "rotating a password changes the checksum, so a rollout is triggered" \
      "both renders produced $c1"
  fi
}

# --- guards ------------------------------------------------------------------

scenario_guards() {
  case_start "bad configuration fails the render instead of half-applying"

  expect_fail "rejects an empty backends list" "backends" \
    render "$(mutate '/^  - name:/,/^    nodePort:/d')"

  expect_fail "rejects a nodePort below the range" "nodePort" \
    render "$(mutate 's/nodePort: 30643/nodePort: 20000/')"
  expect_fail "rejects a nodePort above the range" "nodePort" \
    render "$(mutate 's/nodePort: 30643/nodePort: 40000/')"
  expect_fail "rejects a duplicate nodePort" "nodePort" \
    render "$(mutate 's/nodePort: 30644/nodePort: 30643/')"

  expect_fail "rejects a duplicate name" "name" \
    render "$(mutate 's/name: test-prod/name: test/')"
  # Service port names are capped at 15 characters.
  #
  # Checked by LENGTH rather than by eyeballing the name, because this test has already been made
  # vacuous once: it used a 16-character name, a later rename shortened it to 13, and the guard
  # below correctly stopped firing -- so the assertion passed for the wrong reason until someone
  # noticed the suite was red. Assert the premise, not just the conclusion.
  over=$(mutate 's/name: test-prod/name: test-prod-frontend/')
  over_len=$(yq -r '.backends[1].name | length' "$over")
  if [ "$over_len" -gt 15 ]; then
    pass "the over-long fixture name really is over 15 characters ($over_len)"
  else
    fail "the over-long fixture name really is over 15 characters" \
      "it is $over_len, so the guard below cannot fire and would pass vacuously"
  fi
  expect_fail "rejects an over-long name" "15" render "$over"
  expect_fail "rejects an uppercase or underscored name" "name" \
    render "$(mutate 's/name: test-prod/name: Next_QA/')"
  expect_fail "rejects an all-digit name" "name" \
    render "$(mutate 's/name: test-prod/name: 6443/')"

  # There are deliberately no localPort guards: the port a tunnel listens on inside the pod is
  # derived from the entry's position, so there is nothing to duplicate or to bind below 1024.

  expect_fail "rejects a missing host" "host" \
    render "$(mutate '/^ *host:/d')"
  expect_fail "rejects a missing password" "password" \
    render "$(mutate '/^ *password:/d')"
  # dest is top-level, not per-backend: it mirrors each backend's restrictTo, which is the same
  # for all of them. Note this must be forced EMPTY rather than deleted -- Helm merges -f values
  # over the chart's own defaults, so omitting the key just falls back to the default.
  expect_fail "rejects an empty dest" "dest" render "$FIXTURE" --set dest=

  expect_fail "rejects a host carrying a scheme" "scheme" \
    render "$(mutate 's|host: test.test.com|host: https://test.test.com|')"
  expect_fail "rejects a prefix with a leading slash" "prefix" \
    render "$(mutate 's|prefix: alpha|prefix: /alpha|')"
}

scenario_newline_password() {
  case_start "a password containing a newline is rejected, not mangled"
  d=$(new_tmp)
  sed 's|password: "p@.*|password: "line1\\nline2"|' "$FIXTURE" >"$d/values.yaml"
  expect_fail "rejects a newline in a password" "newline" render "$d/values.yaml"
}

# --- run ---------------------------------------------------------------------

suite "chart"
if [ ! -d "$CHART" ]; then
  fail "chart exists" "$CHART is missing"
  summary "chart"
  exit 1
fi

scenario_shape
scenario_service_ports
scenario_secrets
scenario_supervisor_script
scenario_volumes
scenario_port_consistency
scenario_notes
scenario_notes_cardinality
scenario_deployment_hardening
scenario_checksum
scenario_guards
scenario_newline_password
summary "chart"
