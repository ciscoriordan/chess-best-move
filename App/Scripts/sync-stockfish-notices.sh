#!/bin/sh
# Copies Stockfish's license text and author list from the vendored engine source into the
# app's resources, where the Settings > Licenses and Chess engine screens read them.
#
# Run it after re-vendoring Stockfish (Packages/ChessEngine/scripts/vendor-stockfish.sh).
# The copies are needed because the ChessEngine package excludes these files from its own
# target. App/Tests/Unit/Settings/SettingsLicensesTests.swift fails when they drift.
set -eu

root="$(cd "$(dirname "$0")/../.." && pwd)"
source_dir="$root/Packages/ChessEngine/Sources/CStockfish/stockfish"
destination="$root/App/Resources/Settings"

mkdir -p "$destination"
cp "$source_dir/Copying.txt" "$destination/Stockfish-Copying.txt"
cp "$source_dir/AUTHORS" "$destination/Stockfish-AUTHORS.txt"
echo "Copied Stockfish $(cat "$source_dir/VENDORED_TAG") notices to App/Resources/Settings"
