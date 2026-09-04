#!/bin/sh
# Verifies the macOS marketing version against VERSION and an optional release tag.

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
version_file="$root/VERSION"
project_yml="$root/macos/project.yml"

for f in "$version_file" "$project_yml"; do
    if [ ! -f "$f" ]; then
        echo "check-version: missing $f" >&2
        exit 1
    fi
done

expected=$(tr -d ' \t\r\n' < "$version_file")
if [ -z "$expected" ]; then
    echo "check-version: VERSION is empty" >&2
    exit 1
fi

found=$(sed -n 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"\{0,1\}\([^"[:space:]]*\)"\{0,1\}[[:space:]]*$/\1/p' "$project_yml")
if [ -z "$found" ]; then
    echo "check-version: no MARKETING_VERSION found in macos/project.yml" >&2
    exit 1
fi

status=0
for v in $found; do
    if [ "$v" != "$expected" ]; then
        echo "check-version: macos/project.yml has MARKETING_VERSION $v, VERSION says $expected" >&2
        status=1
    fi
done

tag=${1:-}
if [ -n "$tag" ]; then
    if [ "$tag" != "v$expected" ]; then
        echo "check-version: tag $tag does not match VERSION $expected (expected v$expected)" >&2
        status=1
    else
        echo "check-version: tag $tag matches VERSION"
    fi
fi

if [ "$status" -eq 0 ]; then
    echo "check-version: $expected (macos/project.yml agrees with VERSION)"
fi
exit "$status"
