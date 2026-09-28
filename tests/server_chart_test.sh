#!/bin/sh
# Rendering and guard tests for charts/k8s-tunnel-server -- the BACKEND side.
#
# This chart had no tests, and it showed. A helper that called randAlphaNum was `include`d from
# three templates, and Helm re-executes a named template at EVERY include, so a single render
# produced three different values: the prefix the server enforced (from the Secret), the path nginx
# routed (from the Ingress), and the URL printed to the operator. A fresh install was therefore
# broken -- nginx 404'd, and even the correct path would have been refused by the server -- until
# the first `helm upgrade` happened to reconcile them via `lookup`. The basic-auth password had the
# same shape: the plaintext stored for retrieval was bcrypt'd from a DIFFERENT value than the hash
# nginx validates, so "read it from the Secret" handed out a password that always returned 401.
#
# The chart now generates both secrets again, which is only safe because a generated value is
# computed ONCE and the objects that must agree on it are emitted together. These tests pin that:
#
#   scenario_generated_mode   the regression itself, in generated mode -- the mode that used to be
#                             broken and that the explicit-value tests never exercise
#   scenario_prefix_agreement / scenario_password_matches_hash
#                             the same properties with explicit values, plus that they are honoured
#
# Needs htpasswd (macOS ships it at /usr/sbin/htpasswd; Linux: apache2-utils or httpd-tools) --
# the only way to prove the stored plaintext actually authenticates.

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
CHART="$ROOT/charts/k8s-tunnel-server"
. "$HERE/lib.sh"

RELEASE="k8s-tunnel-server"
NS="k8s-tunnel-server"
HOST="backend.example.test"
# Fixed, not generated: a failure must be reproducible.
PREFIX="aaaabbbbccccddddeeeeffff0000111122223333"
PASS="test-password-not-a-real-one"

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

image_args() {
  printf '%s\n' --set image.repository=mirror/wstunnel --set image.tag=v11.0.0
}

# Explicit secrets: deterministic, and the escape hatch for render tooling with no cluster access.
explicit_args() {
  printf '%s\n' --set "ingress.host=$HOST" --set "pathPrefix=$PREFIX" --set "basicAuth.password=$PASS"
}

render() { # <args...>
  helm template "$RELEASE" "$CHART" -n "$NS" "$@"
}

# No explicit secrets AND no cluster, so `lookup` is empty and the chart genuinely generates.
# NEVER add --validate or --dry-run=server here: either gives the render a real client, the lookup
# becomes meaningful, and this whole guard stops biting.
render_generated() { # [extra args...]
  # shellcheck disable=SC2046
  helm template "$RELEASE" "$CHART" -n "$NS" $(image_args) --set "ingress.host=$HOST" "$@"
}

# NOTES and the manifest must come from ONE render. `helm template` does not render NOTES at all,
# and a second `helm install --dry-run` would be a different render with a different generated
# prefix -- so comparing the two would be comparing unrelated values.
install_dry_run() { # [extra args...]
  # shellcheck disable=SC2046
  helm install "$RELEASE" "$CHART" -n "$NS" --dry-run $(image_args) "$@" 2>&1
}

manifest_of() { sed -n '/^MANIFEST:/,/^NOTES:/{/^MANIFEST:/d;/^NOTES:/d;p;}' "$1"; }
notes_of() { sed -n '/^NOTES:/,$p' "$1"; }

prefix_of() { # <manifest file>
  yq "select(.kind==\"Secret\" and .metadata.name==\"$RELEASE-auth\") | .stringData.prefix" "$1" | tr -d '"'
}
ingress_path_of() { # <manifest file>
  yq 'select(.kind=="Ingress") | .spec.rules[0].http.paths[0].path' "$1" | sed 's|^/||'
}
password_of() { # <manifest file>
  yq "select(.kind==\"Secret\" and .metadata.name==\"$RELEASE-basic-auth\") | .stringData.password" "$1" | tr -d '"'
}
auth_hash_of() { # <manifest file>
  yq "select(.kind==\"Secret\" and .metadata.name==\"$RELEASE-basic-auth\") | .stringData.auth" "$1" | sed 's/^[^:]*://' | tr -d '"'
}

# The ONLY way to prove the retrievable plaintext is the one nginx validates: a bcrypt hash is
# one-way, so it has to be checked, not compared.
assert_password_authenticates() { # <label> <manifest file>
  _pw=$(password_of "$2"); _hash=$(auth_hash_of "$2")
  printf 'tunnel:%s\n' "$_hash" >"$2.htpasswd"
  if htpasswd -vb "$2.htpasswd" tunnel "$_pw" >/dev/null 2>&1; then
    pass "$1"
  else
    fail "$1" "the plaintext handed out to clients would always return 401"
  fi
}

# --- scenarios ---------------------------------------------------------------

scenario_generated_mode() {
  case_start "generated mode: computed once, and the objects agree"
  d=$(new_tmp)

  install_dry_run --set "ingress.host=$HOST" >"$d/run1.txt"
  manifest_of "$d/run1.txt" >"$d/m1.yaml"
  notes_of "$d/run1.txt" >"$d/n1.txt"

  # Bail out loudly if the render failed. Without this, every extraction below yields an empty
  # string and the agreement assertions "pass" by comparing nothing to nothing.
  if ! yq 'select(.kind=="Secret") | .kind' "$d/m1.yaml" >/dev/null 2>&1 ||
     [ -z "$(yq 'select(.kind=="Secret") | .kind' "$d/m1.yaml" 2>/dev/null)" ]; then
    fail "the chart renders in generated mode" "$(head -3 "$d/run1.txt")"
    return
  fi
  pass "the chart renders in generated mode"

  s=$(prefix_of "$d/m1.yaml")
  i=$(ingress_path_of "$d/m1.yaml")

  # THE regression: two generated values means nginx routes a path the server then refuses, and
  # every client 404s with nothing anywhere saying why.
  assert_eq "the Ingress routes exactly the prefix the server enforces" "$s" "$i"

  # Equality alone is not enough -- a regression that made BOTH empty would still be equal.
  if [ -n "$s" ] && [ "$(printf '%s' "$s" | wc -c | tr -d ' ')" = "48" ] &&
     printf '%s' "$s" | grep -qE '^[a-z0-9]+$'; then
    pass "the prefix is non-empty, 48 chars of [a-z0-9]"
  else
    fail "the prefix is non-empty, 48 chars of [a-z0-9]" "got [$s]"
  fi

  # The invariant the whole fix rests on, asserted structurally: one template execution emitted
  # both objects. This fails the instant someone splits the file back into two.
  srcs=$(grep -c 'Source: k8s-tunnel-server/templates/published-path.yaml' "$d/m1.yaml")
  assert_eq "both objects come from the single merged template" "2" "$srcs"

  assert_password_authenticates "the generated password authenticates against its own hash" "$d/m1.yaml"

  # NOTES is a different variable scope, so it cannot see what that file generated. It must hand
  # over a way to READ the value rather than printing one of its own -- which is exactly how the
  # original bug printed a URL matching neither the Secret nor the Ingress.
  assert_file_not_contains "the install output does not print a prefix matching nothing" "$d/n1.txt" "$s"
  assert_file_matches "the prefix line gives a retrieval command, not a value" "$d/n1.txt" \
    "prefix: +kubectl .*jsonpath='\{\.data\.prefix\}'"

  # ...and that equality is not vacuous: the chart really is generating, not returning a constant.
  render_generated >"$d/g2.yaml"
  s2=$(prefix_of "$d/g2.yaml")
  if [ "$s" != "$s2" ]; then
    pass "a second render generates a different prefix (generation is live)"
  else
    fail "a second render generates a different prefix (generation is live)" \
      "both renders produced [$s] -- the agreement above proves nothing"
  fi
}

scenario_explicit_values() {
  case_start "explicit values are honoured, and pin the prefix across renders"
  d=$(new_tmp); render $(explicit_args) >"$d/a.yaml" 2>/dev/null || {
    fail "the chart renders with explicit values" "$(render $(explicit_args) 2>&1 | head -2)"; return; }

  assert_eq "the prefix is exactly what was passed in" "$PREFIX" "$(prefix_of "$d/a.yaml")"
  assert_eq "the Ingress routes that same prefix" "$PREFIX" "$(ingress_path_of "$d/a.yaml")"
  assert_eq "the stored plaintext is exactly what was passed in" "$PASS" "$(password_of "$d/a.yaml")"
  assert_password_authenticates "the stored plaintext authenticates against the stored hash" "$d/a.yaml"

  hash=$(auth_hash_of "$d/a.yaml")
  case "$hash" in
    '$2a$'*|'$2y$'*|'$2b$'*) pass "the hash is bcrypt" ;;
    *) fail "the hash is bcrypt" "got: $hash" ;;
  esac

  # Deliberately NOT byte-identical: sprig's htpasswd salts freshly on every call, so `auth` differs
  # between renders even with identical inputs. Pinning the prefix is the property that matters.
  render $(explicit_args) >"$d/b.yaml" 2>/dev/null
  assert_eq "the prefix is stable across renders when pinned" \
    "$(prefix_of "$d/a.yaml")" "$(prefix_of "$d/b.yaml")"

  ref=$(yq 'select(.kind=="Deployment") | .spec.template.spec.containers[0].env[] | select(.name=="WSTUNNEL_RESTRICT_HTTP_UPGRADE_PATH_PREFIX") | .valueFrom.secretKeyRef.name' "$d/a.yaml")
  assert_eq "the Deployment reads the prefix from the Secret holding it" "$RELEASE-auth" "$ref"
}

scenario_rollout_on_prefix_change() {
  case_start "the pod rolls when the published path changes"
  d=$(new_tmp)
  c1=$(render $(explicit_args) 2>/dev/null | yq 'select(.kind=="Deployment") | .spec.template.metadata.annotations."checksum/prefix"')
  c2=$(render $(explicit_args) --set pathPrefix=someotherprefixvalue 2>/dev/null | \
       yq 'select(.kind=="Deployment") | .spec.template.metadata.annotations."checksum/prefix"')

  # The prefix reaches the container through a secretKeyRef, resolved at container START. Without
  # this annotation a prefix change updates the Secret and the Ingress while the running server
  # keeps enforcing the old value -- nginx routes a path the server refuses, and every client 404s.
  if [ -n "$c1" ] && [ "$c1" != "null" ]; then
    pass "the pod template carries a prefix checksum"
  else
    fail "the pod template carries a prefix checksum" "nothing would restart the pod on a prefix change"
  fi
  if [ "$c1" != "$c2" ]; then
    pass "changing the prefix changes the checksum, so the pod rolls"
  else
    fail "changing the prefix changes the checksum, so the pod rolls" "both were $c1"
  fi
}

scenario_guards() {
  case_start "the guards that apply, and the one that no longer should"

  out=$(render $(image_args) 2>&1)
  assert_contains "ingress.host is still required when the Ingress is enabled" \
    "ingress.host is required" "$out"

  # Two sources of truth for one value: the Ingress would route one path while the server enforced
  # whatever the external Secret holds.
  out=$(render $(image_args) --set "ingress.host=$HOST" --set existingSecret=someone-elses --set pathPrefix=abc 2>&1)
  assert_contains "existingSecret together with pathPrefix is refused" "never both" "$out"

  # A cluster-less render cannot resolve an external Secret, and must say so rather than mint a
  # prefix that Secret does not contain.
  out=$(render $(image_args) --set "ingress.host=$HOST" --set existingSecret=someone-elses 2>&1)
  assert_contains "an unresolvable existingSecret fails instead of minting a prefix" \
    "does not exist" "$out"
}

scenario_ingress_disabled() {
  case_start "with the Ingress off the server still gets its prefix"
  d=$(new_tmp); render $(image_args) --set ingress.enabled=false >"$d/m.yaml" 2>&1

  # The prefix Secret is what feeds the Deployment, so it must survive a disabled Ingress.
  s=$(prefix_of "$d/m.yaml")
  if [ -n "$s" ] && [ "$s" != "null" ]; then
    pass "the prefix Secret is still emitted"
  else
    fail "the prefix Secret is still emitted" "the server would have no prefix to enforce"
  fi
  n=$(yq 'select(.kind=="Ingress") | .metadata.name' "$d/m.yaml" | tr -d '"')
  assert_eq "no Ingress is emitted" "" "$n"
}

scenario_notes() {
  case_start "the install output is the four fields, and nothing else"
  d=$(new_tmp)
  install_dry_run $(explicit_args) >"$d/run.txt"
  notes_of "$d/run.txt" >"$d/notes.txt"

  assert_file_matches "host" "$d/notes.txt" "host: +$HOST"
  assert_file_matches "prefix" "$d/notes.txt" "prefix: +kubectl .*jsonpath='\{\.data\.prefix\}'"
  assert_file_matches "user" "$d/notes.txt" "user: +tunnel"
  assert_file_matches "Password" "$d/notes.txt" "Password: +kubectl .*jsonpath='\{\.data\.password\}'"

  # Neither generated secret may appear as a literal, even when the operator supplied it. The line
  # is a way to fetch it, which reads the same on a first install as on the fiftieth upgrade.
  assert_file_not_contains "the prefix is not printed as a value" "$d/notes.txt" "$PREFIX"
  assert_file_not_contains "the password is not printed as a value" "$d/notes.txt" "$PASS"

  # The two things that stop this breaking silently: how to read the values (asserted per-field
  # just above), and the warning that a cluster-less render would otherwise mint a new prefix on
  # every run.
  #
  # The output must NOT point at a script. It once did, and that script read the cluster -- which
  # is precisely what the person reading this output cannot do, since reaching the cluster is what
  # the tunnel is for. A `scripts/` path here is a promise the reader may not be able to keep.
  assert_file_not_contains "it points at no script" "$d/notes.txt" "scripts/"
  assert_file_matches "the pinning warning names pathPrefix" "$d/notes.txt" "pathPrefix"
  assert_file_matches "and names the renderers it matters for" "$d/notes.txt" "Argo CD"

  # Kept short on purpose -- it was ~60 lines and buried the four values it exists to convey.
  lines=$(grep -c . "$d/notes.txt")
  if [ "$lines" -le 16 ]; then
    pass "the output stays short ($lines non-blank lines)"
  else
    fail "the output stays short" "$lines non-blank lines"
  fi
}

scenario_ingress_tls() {
  case_start "TLS terminated at the Ingress, and the redirect annotation"
  d=$(new_tmp)

  # Default must stay OFF. The chart is built for an LB terminating TLS and forwarding plain HTTP;
  # emitting a `tls:` block by default would point ingress-nginx at a Secret that does not exist.
  render $(image_args) --set "ingress.host=$HOST" >"$d/plain.yaml" 2>/dev/null
  assert_eq "no tls block by default" "null" \
    "$(yq 'select(.kind=="Ingress") | .spec.tls' "$d/plain.yaml")"

  render $(image_args) --set "ingress.host=$HOST" \
    --set ingress.tls.enabled=true --set ingress.tls.secretName=tunnel-tls >"$d/tls.yaml" 2>/dev/null
  assert_eq "the tls block names the configured Secret" "tunnel-tls" \
    "$(yq 'select(.kind=="Ingress") | .spec.tls[0].secretName' "$d/tls.yaml" | tr -d '"')"
  # Naming the right Secret is not enough -- it has to be for the host being published, or nginx
  # serves the certificate for some other vhost and every client rejects it.
  assert_eq "and covers the published host" "$HOST" \
    "$(yq 'select(.kind=="Ingress") | .spec.tls[0].hosts[0]' "$d/tls.yaml" | tr -d '"')"

  # secretName is optional. A tls entry that lists a host and names no Secret is a working
  # configuration, not a half-finished one: ingress-nginx still forces the HTTPS redirect and
  # serves its --default-ssl-certificate. So the key must be OMITTED, not emitted empty -- an
  # explicit `secretName: ""` is a different thing to hand a controller.
  render $(image_args) --set "ingress.host=$HOST" --set ingress.tls.enabled=true >"$d/nosecret.yaml" 2>/dev/null
  assert_eq "the tls block still lists the host when no Secret is named" "$HOST" \
    "$(yq 'select(.kind=="Ingress") | .spec.tls[0].hosts[0]' "$d/nosecret.yaml" | tr -d '"')"
  assert_eq "and omits secretName rather than emitting an empty one" "null" \
    "$(yq 'select(.kind=="Ingress") | .spec.tls[0].secretName' "$d/nosecret.yaml")"

  # The redirect. Both directions matter: false is what keeps an SLB deployment out of a loop.
  assert_eq "force-ssl-redirect defaults to false" "false" \
    "$(yq 'select(.kind=="Ingress") | .metadata.annotations."nginx.ingress.kubernetes.io/force-ssl-redirect"' "$d/plain.yaml" | tr -d '"')"
  render $(image_args) --set "ingress.host=$HOST" --set ingress.forceSSLRedirect=true >"$d/redir.yaml" 2>/dev/null
  assert_eq "and follows the value when it is set" "true" \
    "$(yq 'select(.kind=="Ingress") | .metadata.annotations."nginx.ingress.kubernetes.io/force-ssl-redirect"' "$d/redir.yaml" | tr -d '"')"
}

# --- run ---------------------------------------------------------------------

suite "server chart"
if ! command -v htpasswd >/dev/null 2>&1; then
  fail "htpasswd is available" \
    "install it (macOS: preinstalled; Linux: apache2-utils or httpd-tools). Without it the password/hash equivalence cannot be checked, and skipping that check is how this chart shipped a password that never worked."
  summary "server chart"
  exit 1
fi

scenario_generated_mode
scenario_explicit_values
scenario_rollout_on_prefix_change
scenario_guards
scenario_ingress_disabled
scenario_ingress_tls
scenario_notes
summary "server chart"
