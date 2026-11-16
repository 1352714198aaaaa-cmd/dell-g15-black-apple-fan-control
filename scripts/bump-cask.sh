#!/bin/bash
set -euo pipefail

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
  echo "usage: $0 <version>  (example: $0 2.1.0)" >&2
  exit 1
fi
VERSION="${VERSION#v}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CASK="$ROOT/Casks/g15-fanctl.rb"
REPO="1352714198aaaaa-cmd/dell-g15-black-apple-fan-control"
URL="https://github.com/$REPO/releases/download/v$VERSION/FanCtl-v$VERSION.zip"

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

echo "downloading $URL"
if ! curl -fL --retry 3 --connect-timeout 15 -o "$TMP" "$URL"; then
  echo "download failed: publish the v$VERSION release asset first" >&2
  exit 1
fi

SHA=$(shasum -a 256 "$TMP" | awk '{print $1}')
VERSION="$VERSION" SHA="$SHA" perl -0pi -e '
  s/^  version ".*"/  version "$ENV{VERSION}"/m;
  s/^  sha256 ".*"/  sha256 "$ENV{SHA}"/m;
' "$CASK"

ruby -c "$CASK"
grep -nE '^  (version|sha256) ' "$CASK"
echo
echo "updated Casks/g15-fanctl.rb to $VERSION ($SHA)"
echo "review with: git diff -- Casks/g15-fanctl.rb"
