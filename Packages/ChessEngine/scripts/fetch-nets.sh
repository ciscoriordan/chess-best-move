#!/bin/sh
# Downloads the NNUE network file(s) that the vendored Stockfish release expects
# into Sources/ChessEngine/NNUE and verifies each one.
#
# The file names are read from the vendored src/evaluate.h (every
# `#define EvalFileDefaultName*` macro, so it works both for Stockfish 19, which
# has a single network, and for 17.x/18, which had Big and Small networks).
#
# Verification: every network must have its full SHA-256 pinned in
# pinned_sha256() below, and the file must match it exactly. Stockfish names a
# network nn-<first 12 hex digits of its SHA-256>.nnue, but those 12 digits pin
# only 48 bits, so the name alone is checked only as an extra sanity check (the
# pinned hash must start with the digits in the name).
#
# Usage: scripts/fetch-nets.sh [--force]
set -eu

PKG_DIR=$(cd "$(dirname "$0")/.." && pwd)
EVALUATE_H="$PKG_DIR/Sources/CStockfish/stockfish/src/evaluate.h"
DEST_DIR="$PKG_DIR/Sources/ChessEngine/NNUE"
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

# Full SHA-256 of every network this package accepts, like SF_TARBALL_SHA256 in
# vendor-stockfish.sh. When a Stockfish upgrade names a new network, add its line
# here (and to README.md, "Network") before running this script; see the error
# message below for how to obtain the hash.
pinned_sha256() {
  case "$1" in
    nn-1a298aa575a0.nnue) echo "1a298aa575a085434d29027978dc36867fe9c5bcea9376654b7a8eba1e52dfc2" ;;
    *) echo "" ;;
  esac
}

if [ ! -f "$EVALUATE_H" ]; then
  echo "error: $EVALUATE_H not found (run scripts/vendor-stockfish.sh first)" >&2
  exit 1
fi

if command -v shasum >/dev/null 2>&1; then
  sha256() { shasum -a 256 "$1" | cut -c 1-64; }
elif command -v sha256sum >/dev/null 2>&1; then
  sha256() { sha256sum "$1" | cut -c 1-64; }
else
  echo "error: neither shasum nor sha256sum is available" >&2
  exit 1
fi

NAMES=$(grep -E '^[[:space:]]*#define[[:space:]]+EvalFileDefaultName' "$EVALUATE_H" |
  sed -E 's/.*"(nn-[0-9a-f]{12}\.nnue)".*/\1/' | sort -u)

if [ -z "$NAMES" ]; then
  echo "error: no EvalFileDefaultName macro found in $EVALUATE_H" >&2
  exit 1
fi

# Every referenced network needs a pinned hash that agrees with its name. Checked
# for all names before anything is downloaded or deleted.
for NAME in $NAMES; do
  if ! echo "$NAME" | grep -Eqx 'nn-[0-9a-f]{12}\.nnue'; then
    echo "error: unexpected network name '$NAME' in $EVALUATE_H" >&2
    exit 1
  fi
  PINNED=$(pinned_sha256 "$NAME")
  if [ -z "$PINNED" ]; then
    cat >&2 <<MSG
error: no pinned SHA-256 for $NAME in $0.
To pin it, download it from both sources this script uses:
  https://tests.stockfishchess.org/api/nn/$NAME
  https://github.com/official-stockfish/networks/raw/master/$NAME
compute each file's hash (shasum -a 256), check that the two hashes are equal and
start with the 12 hex digits in the name, then add the hash to pinned_sha256()
and to README.md ("Network") and run this script again.
MSG
    exit 1
  fi
  if ! echo "$PINNED" | grep -Eqx '[0-9a-f]{64}'; then
    echo "error: pinned SHA-256 for $NAME is not 64 lowercase hex digits" >&2
    exit 1
  fi
  NAME_DIGITS=$(echo "$NAME" | sed -E 's/^nn-([0-9a-f]{12})\.nnue$/\1/')
  if [ "$(echo "$PINNED" | cut -c 1-12)" != "$NAME_DIGITS" ]; then
    echo "error: pinned SHA-256 for $NAME does not start with $NAME_DIGITS" >&2
    exit 1
  fi
done

mkdir -p "$DEST_DIR"

# A network is valid when its full SHA-256 equals the pinned hash for its name
# (which also starts with the 12 hex digits in the name, checked above).
# Arguments: file path, network name (the file may be a .part download).
is_valid() {
  [ "$(sha256 "$1")" = "$(pinned_sha256 "$2")" ]
}

for NAME in $NAMES; do
  TARGET="$DEST_DIR/$NAME"
  if [ "$FORCE" -eq 0 ] && [ -f "$TARGET" ]; then
    if is_valid "$TARGET" "$NAME"; then
      echo "$NAME: present and verified ($(wc -c <"$TARGET" | tr -d ' ') bytes)"
      continue
    fi
    echo "$NAME: present but its SHA-256 $(sha256 "$TARGET") is not the pinned one, downloading again" >&2
  fi

  TMP="$TARGET.part"
  rm -f "$TMP"
  OK=0
  for URL in "https://tests.stockfishchess.org/api/nn/$NAME" \
             "https://github.com/official-stockfish/networks/raw/master/$NAME"; do
    echo "$NAME: downloading $URL"
    if curl -fsSL --retry 3 --max-time 600 -o "$TMP" "$URL"; then
      if is_valid "$TMP" "$NAME"; then
        mv "$TMP" "$TARGET"
        OK=1
        break
      fi
      echo "$NAME: SHA-256 mismatch (got $(sha256 "$TMP"), expected $(pinned_sha256 "$NAME")), discarding" >&2
    fi
    rm -f "$TMP"
  done

  if [ "$OK" -ne 1 ]; then
    echo "error: could not download a valid $NAME" >&2
    exit 1
  fi
  echo "$NAME: verified, sha256 $(sha256 "$TARGET"), $(wc -c <"$TARGET" | tr -d ' ') bytes"
done

# Remove networks that the vendored release no longer references, so the app
# bundle does not ship stale ~80 MB files after a Stockfish upgrade.
for EXISTING in "$DEST_DIR"/nn-*.nnue; do
  [ -e "$EXISTING" ] || continue
  BASE=$(basename "$EXISTING")
  if ! echo "$NAMES" | grep -qx "$BASE"; then
    echo "removing unreferenced network $BASE"
    rm -f "$EXISTING"
  fi
done
