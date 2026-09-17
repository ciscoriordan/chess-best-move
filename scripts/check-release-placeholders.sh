#!/bin/sh
# Release gate: fails an archive while the app's shipped sources still contain a placeholder URL.
#
# The app target runs this as its first build phase (project.yml, "Block archives with
# placeholder URLs"). It checks only when Xcode archives or installs (ACTION=install, which is
# what Product > Archive and `xcodebuild archive` use), so ordinary Debug and Release builds and
# test runs are never blocked by a URL that is still being worked on.
#
#   scripts/check-release-placeholders.sh            # checks only when ACTION=install
#   scripts/check-release-placeholders.sh --always   # checks now, whatever the action
#
# A placeholder is a URL on example.com, example.org or example.net, or a URL whose text
# contains TODO, in App/Sources (Swift) or App/Info.plist. A link to Apple's standard End User
# License Agreement counts as one too: the app is a combined work with Stockfish and therefore
# distributed under GPLv3, whose section 10 forbids the extra restrictions that agreement
# imposes, so the app must link its own terms instead (App/Sources/Monetization,
# MonetizationLegalLinks.termsOfUse). Each match is printed as an Xcode error at its file and
# line. The check also fails when it cannot read the sources, so a build phase that denies it
# access blocks the archive instead of passing it.
set -eu

if [ "${1:-}" != "--always" ] && [ "${ACTION:-}" != "install" ]; then
    exit 0
fi

root="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
pattern='https?://([A-Za-z0-9-]+\.)*example\.(com|org|net)([/:"?#[:space:]]|$)|https?://[^"[:space:]]*TODO|URL\(string: *"[^"]*TODO|https?://([A-Za-z0-9-]+\.)*apple\.com/legal/[^"[:space:]]*stdeula'

# A gate that cannot read the sources must fail, not pass. Anything that stops the walk (a
# sandboxed build phase, wrong permissions, a moved folder) would otherwise leave grep with no
# matches, which reads exactly like a clean tree. Xcode's user script sandbox does exactly this,
# which is why the app target runs this phase with ENABLE_USER_SCRIPT_SANDBOXING off.
files="$(find "$root/App/Sources" -name '*.swift' -type f 2>/dev/null | wc -l | tr -d ' ')"
if [ ! -r "$root/App/Info.plist" ] || [ "$files" -lt 20 ]; then
    echo "error: Release gate: cannot read the shipped sources ($files Swift files under $root/App/Sources," \
         "App/Info.plist readable: $([ -r "$root/App/Info.plist" ] && echo yes || echo no))." \
         "The check cannot run, so the archive is blocked (README.md, \"Release gate\")."
    exit 1
fi

# grep exits 0 with matches, 1 with none and 2 on an error: only 1 means a clean tree.
matches="$(grep -rnE --include='*.swift' "$pattern" "$root/App/Sources")" || [ $? -eq 1 ] || {
    echo "error: Release gate: searching App/Sources failed; the archive is blocked."
    exit 1
}
# App/Info.plist was checked as readable above, so no match is the only other outcome.
plist="$(grep -nE "$pattern" "$root/App/Info.plist" | sed "s|^|$root/App/Info.plist:|" || true)"
all="$(printf '%s\n%s\n' "$matches" "$plist" | sed '/^$/d')"

if [ -z "$all" ]; then
    echo "Release gate: no placeholder or forbidden URLs in App/Sources or App/Info.plist."
    exit 0
fi

printf '%s\n' "$all" | sed -E 's/^([^:]+):([0-9]+):[[:space:]]*(.*)$/\1:\2: error: Placeholder or forbidden URL in shipped source; replace it before archiving: \3/'
count="$(printf '%s\n' "$all" | wc -l | tr -d ' ')"
echo "error: Release gate: $count placeholder or forbidden URL(s) remain in shipped sources (see above). Archives stay blocked until they are replaced (README.md, \"Release gate\")."
exit 1
