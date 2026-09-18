#!/bin/sh
# Release check: the source links this build shows must open.
#
#   scripts/check-release-source-tag.sh [--version 1.0] [--require-network] [--timeout 8]
#
# Settings > About > Licenses offers the Corresponding Source of the running build, which GPLv3
# section 6(d) requires, and Settings > Chess engine links the one Stockfish patch, which
# section 5(a) requires. Both URLs are built at run time from the app's own version
# (App/Sources/Settings/SettingsLegal.swift, `sourceURL`): the published repository at the tag
# "v" + CFBundleShortVersionString. Nothing in the sources can be searched for that, because
# the fault is not a string in the code, it is a tag that was never pushed. So this script
# builds the same two URLs and asks GitHub whether they answer.
#
# Everything it needs is read from the files the app is built from, so it cannot drift from
# what the app shows:
#
#   * the repository, from `appSourceRepository` in SettingsLegal.swift;
#   * the patch path, from `stockfishPatch` and `stockfishPatchFile` in the same file;
#   * the version, from MARKETING_VERSION in the environment (Xcode sets it during a build) or
#     from project.yml.
#
# Exit status:
#
#   0  both URLs answered 200. The tag is published.
#   1  GitHub answered, and at least one URL is not there. The tag has to be pushed first
#      before the build is submitted. A tag that has been published is never moved and never
#      deleted: installed copies of an older version keep building that same link, so moving
#      the tag changes what that version offers as its Corresponding Source, and deleting it
#      takes the offer away. A correction to a released version is a new version with a new tag.
#   2  the question could not be asked (no network, no curl). scripts/check-release-placeholders.sh
#      treats this as a skip so an offline archive is not blocked; pass --require-network to
#      turn it into a failure, which is what the run before a submission wants.
set -eu

root="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
legal="$root/App/Sources/Settings/SettingsLegal.swift"
project_yml="$root/project.yml"

version="${MARKETING_VERSION:-}"
timeout=8
require_network=0

while [ $# -gt 0 ]; do
    case "$1" in
        --version) shift; version="${1:-}" ;;
        --timeout) shift; timeout="${1:-8}" ;;
        --require-network) require_network=1 ;;
        -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
        *) echo "check-release-source-tag: unknown option \"$1\"" >&2; exit 2 ;;
    esac
    shift
done

fail() { echo "error: Release check: $*"; exit 1; }
cannot() { echo "note: Release check: $*"; [ "$require_network" -eq 1 ] && exit 1; exit 2; }

[ -r "$legal" ] || cannot "cannot read $legal, so the source links cannot be worked out."

# The repository the app links, as a string literal in SettingsLegal.swift.
repo="$(sed -n 's/.*appSourceRepository = URL(string: "\([^"]*\)").*/\1/p' "$legal" | head -1)"
[ -n "$repo" ] || fail "App/Sources/Settings/SettingsLegal.swift no longer declares appSourceRepository as a URL literal; this check cannot build the links the app shows."

# The patch file and the folder it sits in, as SettingsLegal.swift spells them.
patch_file="$(sed -n 's/.*stockfishPatchFile = "\([^"]*\)".*/\1/p' "$legal" | head -1)"
patch_dir="$(sed -n 's|.*sourceURL(filePath: "\([^"\\]*\)\\(.*|\1|p' "$legal" | head -1)"

if [ -z "$version" ] && [ -r "$project_yml" ]; then
    version="$(sed -n 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"\{0,1\}\([^"[:space:]]*\)"\{0,1\}[[:space:]]*$/\1/p' "$project_yml" | head -1)"
fi
[ -n "$version" ] || fail "no version to build a tag from (MARKETING_VERSION is unset and project.yml does not give one)."

tag="v$version"
tree_url="$repo/tree/$tag"
[ -n "$patch_file" ] && [ -n "$patch_dir" ] &&
    patch_url="$repo/blob/$tag/$patch_dir$patch_file" || patch_url=""

command -v curl > /dev/null 2>&1 || cannot "curl is not available, so $tree_url was not checked."

status_of() {
    # Prints the HTTP status, or nothing when the request could not be made at all.
    curl -sS -L -o /dev/null -w '%{http_code}' --max-time "$timeout" "$1" 2>/dev/null || true
}

unreachable=0
bad=0
for url in $tree_url $patch_url; do
    code="$(status_of "$url")"
    case "$code" in
        200) echo "  200  $url" ;;
        ''|000) echo "  ---  $url (no answer)"; unreachable=1 ;;
        *)   echo "  $code  $url"; bad=1 ;;
    esac
done

if [ "$unreachable" -eq 1 ] && [ "$bad" -eq 0 ]; then
    cannot "GitHub could not be reached, so the tag $tag was not checked."
fi

if [ "$bad" -eq 1 ]; then
    echo "error: Release check: the published source of version $version is not there."
    echo "note: The app builds these links from its own version, so every copy of this build shows them."
    echo "note: Push the tag $tag on $repo, on the commit the submitted build was exported from:"
    echo "note:   git tag -a $tag -m \"Chess Best Move $version source\" <commit> && git push origin $tag"
    echo "note: Once pushed, a tag is never moved and never deleted: installed copies of that version keep building this same link."
    exit 1
fi

echo "Release check: the published source of version $version is there ($tag)."
exit 0
