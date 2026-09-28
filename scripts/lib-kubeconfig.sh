#!/usr/bin/env bash
# Shared kubeconfig construction for the tunnel tooling.
#
# Sourced by:
#   connect.sh          -- tunnel is a local process on 127.0.0.1:<port>
#   front-kubeconfig.sh -- tunnel is a NodePort on a front cluster
#
# The two flows differ ONLY in the server URL and the name suffix. Everything else is shared,
# deliberately: the distinct-name rule, the CA fetch, the exec-plugin rejection and the atomic
# publish are exactly the parts that must not be allowed to drift into two copies.
#
# Requires: SOURCE_KUBECONFIG (a kubeconfig for the BACKEND cluster), kubectl on PATH.
# Reads:    KUBECONFIG_OUT (optional; defaults to ~/.kube/<name>.yaml)
#
# Not executable on its own.

# write_tunneled_kubeconfig <server-url> <name-suffix>
#
# <name-suffix> is appended to the source context name to form the kubeconfig's cluster, context
# and file name, e.g. "-tunnel" or "-svc-tunnel". It must start with "-". The suffix is how the
# two flows stay distinguishable in a shared folder; see the note below.
#
# Echoes the path written to stdout. All human-readable output goes to stderr, so a caller's
# stdout stays clean.
write_tunneled_kubeconfig() {
  local server_url="$1"
  local name_suffix="$2"
  local src_ctx src_user name kc work new cert token dest_tmp

  case "$name_suffix" in
    -*) ;;
    *) echo "ERROR: name suffix must start with '-' (got '${name_suffix}')" >&2; return 1 ;;
  esac

  : "${SOURCE_KUBECONFIG:?set SOURCE_KUBECONFIG to an existing kubeconfig for the cluster being tunnelled to}"

  src_ctx="$(kubectl --kubeconfig "$SOURCE_KUBECONFIG" config current-context)"
  src_user="$(kubectl --kubeconfig "$SOURCE_KUBECONFIG" config view \
              -o jsonpath="{.contexts[?(@.name=='${src_ctx}')].context.user}")"

  # Distinct names BY CONSTRUCTION, and the suffix is what keeps the two flows apart.
  #
  # Kubeconfigs overwhelmingly name their cluster "cluster.local", and ~/.kube accumulates one
  # file per environment -- two of them declaring the same cluster name with different servers is
  # a collision. kubectl has no `rename-cluster` subcommand, so this cannot be corrected
  # afterwards; it has to be built right the first time.
  #
  # The suffix matters for a second reason: connect.sh writes <ctx>-tunnel while
  # front-kubeconfig.sh writes <ctx>-svc-tunnel. Same context, different servers. If they shared
  # a name, the two would collide in exactly the way described above.
  name="${src_ctx}${name_suffix}"

  kc="${KUBECONFIG_OUT:-$HOME/.kube/${name}.yaml}"
  mkdir -p "$(dirname "$kc")"

  work="$(mktemp -d)"

  # The source kubeconfig carries NO CA (it relies on insecure-skip-tls-verify), so the CA
  # comes from the cluster's kube-root-ca.crt ConfigMap.
  kubectl --kubeconfig "$SOURCE_KUBECONFIG" -n default get cm kube-root-ca.crt \
    -o jsonpath='{.data.ca\.crt}' >"$work/ca.crt"

  new="$work/kubeconfig"
  kubectl --kubeconfig "$new" config set-cluster "$name" \
    --server="$server_url" \
    --certificate-authority="$work/ca.crt" --embed-certs=true >/dev/null

  # Carry the source credentials across. Client certs and bearer tokens are both supported;
  # exec/auth-provider credential plugins are not, and say so -- rather than producing a
  # kubeconfig that loads fine and silently cannot authenticate.
  cert="$(kubectl --kubeconfig "$SOURCE_KUBECONFIG" config view --raw \
          -o jsonpath="{.users[?(@.name=='${src_user}')].user.client-certificate-data}")"
  if [ -n "$cert" ]; then
    kubectl --kubeconfig "$SOURCE_KUBECONFIG" config view --raw \
      -o jsonpath="{.users[?(@.name=='${src_user}')].user.client-certificate-data}" \
      | base64 -d >"$work/client.crt"
    kubectl --kubeconfig "$SOURCE_KUBECONFIG" config view --raw \
      -o jsonpath="{.users[?(@.name=='${src_user}')].user.client-key-data}" \
      | base64 -d >"$work/client.key"
    kubectl --kubeconfig "$new" config set-credentials "$src_user" \
      --client-certificate="$work/client.crt" --client-key="$work/client.key" \
      --embed-certs=true >/dev/null
  else
    token="$(kubectl --kubeconfig "$SOURCE_KUBECONFIG" config view --raw \
             -o jsonpath="{.users[?(@.name=='${src_user}')].user.token}")"
    if [ -z "$token" ]; then
      echo "ERROR: user '${src_user}' has neither a client certificate nor a token." >&2
      echo "       exec / auth-provider credential plugins are not carried across." >&2
      rm -rf "$work"; return 1
    fi
    kubectl --kubeconfig "$new" config set-credentials "$src_user" --token="$token" >/dev/null
  fi

  kubectl --kubeconfig "$new" config set-context "$name" \
    --cluster="$name" --user="$src_user" >/dev/null
  kubectl --kubeconfig "$new" config use-context "$name" >/dev/null
  # kubernetes.default.svc IS in the API server certificate's SAN list, so verification passes
  # without touching the control plane. An x509 name error means fix THIS -- never add
  # insecure-skip-tls-verify.
  kubectl --kubeconfig "$new" config set "clusters.${name}.tls-server-name" \
    kubernetes.default.svc >/dev/null

  # Publish atomically. The destination may be a watched directory -- anything that reloads a
  # kubeconfig the moment it appears -- and must never read a half-written file, so write alongside
  # the destination and rename into place.
  dest_tmp="$(dirname "$kc")/.${name}.config.$$"
  install -m 600 "$new" "$dest_tmp"
  mv -f "$dest_tmp" "$kc"
  rm -rf "$work"

  echo "wrote $kc" >&2
  echo "  cluster + context: $name" >&2
  echo "  server:            $server_url" >&2

  printf '%s' "$kc"
}
