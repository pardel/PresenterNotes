#!/usr/bin/env bash
# Package a notarized PresenterNotes.app into a distributable DMG.
#
# Usage: scripts/make-dmg.sh <version>
# Example: scripts/make-dmg.sh 1.0.0
#
# Expects releases/PresenterNotes.app to exist (exported + notarized from Xcode).
# Produces releases/PresenterNotes-<version>.dmg.

set -euo pipefail

VERSION="${1:?usage: make-dmg.sh <version>}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$REPO_ROOT/releases/PresenterNotes.app"
OUT="$REPO_ROOT/releases/PresenterNotes-$VERSION.dmg"

if [[ ! -d "$APP" ]]; then
  echo "error: $APP not found" >&2
  exit 1
fi

if ! xcrun stapler validate "$APP" >/dev/null 2>&1; then
  echo "error: $APP is not stapled — notarize + staple in Xcode first" >&2
  exit 1
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$OUT"
hdiutil create \
  -volname "PresenterNotes $VERSION" \
  -srcfolder "$STAGE" \
  -format UDZO \
  -ov \
  "$OUT" >/dev/null

echo "built: $OUT"
shasum -a 256 "$OUT"
