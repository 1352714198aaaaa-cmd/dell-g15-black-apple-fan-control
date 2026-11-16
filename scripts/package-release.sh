#!/bin/bash
set -euo pipefail

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
  echo "usage: $0 <version>  (example: $0 2.1.0)" >&2
  exit 1
fi
VERSION="${VERSION#v}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

for path in kext/FanProbe.kext ssdt/SSDT-FANEC.aml app/FanCtl.app cli/fanctl; do
  if [ ! -e "$path" ]; then
    echo "missing $path" >&2
    echo "run ./kext/build.sh, ./ssdt/build.sh and ./app/build.sh first" >&2
    exit 1
  fi
done

APP_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' app/FanCtl.app/Contents/Info.plist)
if [ "$APP_VERSION" != "$VERSION" ]; then
  echo "app version is $APP_VERSION, expected $VERSION" >&2
  echo "bump app/Info.plist and rebuild before packaging" >&2
  exit 1
fi

ZIP_NAME="FanCtl-v${VERSION}.zip"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp -R kext/FanProbe.kext "$STAGE/"
cp ssdt/SSDT-FANEC.aml "$STAGE/"
cp -R app/FanCtl.app "$STAGE/"
cp cli/fanctl "$STAGE/"

rm -rf dist
mkdir -p dist
( cd "$STAGE" && zip -qr "$ROOT/dist/$ZIP_NAME" . -x '*.DS_Store' )
( cd dist && shasum -a 256 "$ZIP_NAME" | tee "$ZIP_NAME.sha256" )

echo
echo "release asset: dist/$ZIP_NAME"
echo "checksum:      dist/$ZIP_NAME.sha256"
