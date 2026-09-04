#!/bin/sh
# Package a built EasyShare.app into a drag-to-Applications disk image.
#
#     scripts/make-dmg.sh <path/to/EasyShare.app> <path/to/out.dmg>
#
# The image contains the app and a symlink to /Applications, which is the whole
# install: drag one onto the other. Nothing else is required. macOS registers
# the embedded Finder extension through LaunchServices the first time the app
# is launched from /Applications, and share extensions are enabled on
# registration — there is no pluginkit step and no System Settings step for a
# normal install.
#
# This script does not sign or notarize. Do that to the .app BEFORE calling it,
# and to the .dmg afterwards; see docs/releasing.md.

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

# -R preserves the symlinks and the code signature inside the bundle; a plain
# recursive copy that resolves symlinks would invalidate the signature.
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
