#!/usr/bin/env bash
# Install the wstunnel client.
#
# The version MUST match the server's (charts/k8s-tunnel-server/values.yaml -> image.tag) unless you
# have checked compatibility: client and server negotiate a protocol version, and a mismatch
# fails at the websocket handshake with a status the client reports only as "failed to do
# websocket handshake".
#
# Usage:  ./install-client.sh [dest-dir]        (default: ~/.local/bin)
set -euo pipefail

VERSION="${WSTUNNEL_VERSION:-v11.0.0}"
DEST="${1:-$HOME/.local/bin}"

mkdir -p "$DEST"

case "$(uname -s)-$(uname -m)" in
  Darwin-arm64)   ASSET="wstunnel_${VERSION#v}_darwin_arm64.tar.gz" ;;
  Darwin-x86_64)  ASSET="wstunnel_${VERSION#v}_darwin_amd64.tar.gz" ;;
  Linux-x86_64)   ASSET="wstunnel_${VERSION#v}_linux_amd64.tar.gz" ;;
  Linux-aarch64)  ASSET="wstunnel_${VERSION#v}_linux_arm64.tar.gz" ;;
  *) echo "unsupported platform: $(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac

URL="https://github.com/erebe/wstunnel/releases/download/${VERSION}/${ASSET}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "downloading ${ASSET}"
curl -fsSL "$URL" -o "$TMP/wstunnel.tar.gz"
tar -xzf "$TMP/wstunnel.tar.gz" -C "$TMP" wstunnel
install -m 0755 "$TMP/wstunnel" "$DEST/wstunnel"

"$DEST/wstunnel" --version
echo
echo "installed: $DEST/wstunnel"
case ":$PATH:" in
  *":$DEST:"*) ;;
  *) echo "NOTE: $DEST is not on your PATH; connect.sh calls it by absolute path." ;;
esac
echo
echo "NOT DONE: the download is not checksum-verified. If your environment requires it, fetch"
echo "the release checksums from the same GitHub release page and verify before installing."
