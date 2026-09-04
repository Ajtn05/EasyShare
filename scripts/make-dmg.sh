#!/bin/sh
# Packages EasyShare.app into a drag-to-Applications disk image.

set -eu

app=${1:-}
out=${2:-}

if [ -z "$app" ] || [ -z "$out" ]; then
    echo "usage: $0 <EasyShare.app> <out.dmg>" >&2
    exit 2
fi

if [ ! -d "$app" ]; then
    echo "make-dmg: no app bundle at $app" >&2
    exit 1
fi

staging=$(mktemp -d "${TMPDIR:-/tmp}/easyshare-dmg.XXXXXX")
trap 'rm -rf "$staging"' EXIT INT TERM

# Preserve bundle symlinks and the code signature.
cp -R "$app" "$staging/"
ln -s /Applications "$staging/Applications"

rm -f "$out"
hdiutil create \
    -volname "Easy Share" \
    -srcfolder "$staging" \
    -fs HFS+ \
    -format UDZO \
    -quiet \
    "$out"

echo "make-dmg: wrote $out"
