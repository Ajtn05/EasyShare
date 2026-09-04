#!/bin/sh
# Fails if macos/project.yml's MARKETING_VERSION has drifted from the root
# VERSION file.
#
#     scripts/check-version.sh            # drift check only
#     scripts/check-version.sh v0.5.1     # also require the tag to match
#
# The release workflow passes the tag it was triggered by, so a mistyped tag
# cannot publish a mislabelled build.
#
# VERSION is the single source of the marketing version. Android reads it at
# configuration time (android/app/build.gradle.kts), but XcodeGen has no way to
# read a file, so macos/project.yml carries the literal and this check keeps the
# two honest. Build numbers are NOT covered here: CURRENT_PROJECT_VERSION and
# Android's versionCode are bumped by hand and are allowed to differ.

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
