#!/bin/sh
# Fails an archive built with any Xcode but the one pinned in scripts/release/xcode-version.txt.
#
#   scripts/check-release-xcode.sh            # checks only when ACTION=install
#   scripts/check-release-xcode.sh --always   # checks now, whatever the action
#
# Two Xcodes are installed on this Mac, a release and a beta. App Store Connect rejects a build
# made with a beta Xcode or a beta SDK, and a finished archive does not say which one produced
# it, so the check belongs before the archive rather than after the rejection.
#
# It compares the pinned build version with the one actually running, because that is the value
# that changes between a release and a beta and between two releases. Comparing a path for the
# word "Beta" would be fooled by a renamed folder, and LicenseInfo.plist cannot tell them apart:
# on 2026-09-20 both /Applications/Xcode.app (27.0) and /Applications/Xcode-27.1.0-Beta.app
# reported licenseType GM.
#
# CHESS_BEST_MOVE_XCODE_CHECK=0 turns it off for an archive that will not be submitted.
set -eu

if [ "${1:-}" != "--always" ] && [ "${ACTION:-}" != "install" ]; then
    exit 0
fi
if [ "${CHESS_BEST_MOVE_XCODE_CHECK:-1}" = "0" ]; then
    echo "Release gate: the Xcode version was not checked (CHESS_BEST_MOVE_XCODE_CHECK=0)."
    exit 0
fi

# The pin belongs to this script, not to the tree being checked, so it is resolved next to the
# script rather than under SRCROOT. That also keeps the script tests working, which run the gate
# against fixture trees that have no scripts/release/ of their own.
pin="$(cd "$(dirname "$0")" && pwd)/release/xcode-version.txt"

if [ ! -r "$pin" ]; then
    echo "error: Release gate: $pin is missing, so the Xcode this archive is built with cannot be checked."
    exit 1
fi

want_version="$(sed -n 's/^version[[:space:]]\{1,\}\(.*\)$/\1/p' "$pin" | head -1)"
want_build="$(sed -n 's/^build[[:space:]]\{1,\}\(.*\)$/\1/p' "$pin" | head -1)"
if [ -z "$want_version" ] || [ -z "$want_build" ]; then
    echo "error: Release gate: $pin does not name both a version and a build."
    exit 1
fi

have="$(xcodebuild -version 2>/dev/null || true)"
have_version="$(printf '%s\n' "$have" | sed -n 's/^Xcode[[:space:]]\{1,\}\(.*\)$/\1/p' | head -1)"
have_build="$(printf '%s\n' "$have" | sed -n 's/^Build version[[:space:]]\{1,\}\(.*\)$/\1/p' | head -1)"
if [ -z "$have_build" ]; then
    echo "error: Release gate: could not read the running Xcode version from xcodebuild -version."
    exit 1
fi

if [ "$have_build" != "$want_build" ]; then
    echo "error: Release gate: this archive is being built with Xcode $have_version ($have_build), but submissions are pinned to Xcode $want_version ($want_build)."
    echo "note: Select the pinned Xcode and archive again, for example: sudo xcode-select -s /Applications/Xcode.app"
    echo "note: Developer directory in use: $(xcode-select -p 2>/dev/null || echo unknown)"
    echo "note: If the pinned version is out of date, update scripts/release/xcode-version.txt on purpose, after checking the new Xcode is a release and not a beta."
    echo "note: For an archive that will not be submitted, set CHESS_BEST_MOVE_XCODE_CHECK=0."
    exit 1
fi

echo "Release gate: Xcode $have_version ($have_build) is the pinned submission Xcode."
exit 0
