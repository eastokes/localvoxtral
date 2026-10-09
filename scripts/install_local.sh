#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

SOURCE_APP="$ROOT_DIR/dist/localvoxtral.app"
TARGET_DIR="$HOME/Applications"
TARGET_APP="$TARGET_DIR/localvoxtral.app"

if [[ ! -d "$SOURCE_APP" ]]; then
  echo "Missing packaged app: $SOURCE_APP"
  echo "Run 'mise run package-local' first."
  exit 1
fi

signature_details="$(codesign -dvv "$SOURCE_APP" 2>&1 || true)"
if grep -q '^Signature=adhoc' <<<"$signature_details"; then
  echo "Refusing to install an ad-hoc-signed local build: $SOURCE_APP" >&2
  echo "Ad-hoc signatures change across rebuilds and silently invalidate the app's Accessibility grant." >&2
  echo "Create a stable Code Signing identity, then run 'mise run install-local'." >&2
  echo "See docs/building.md#stable-local-code-signing." >&2
  exit 1
fi
if ! codesign --verify --deep --strict "$SOURCE_APP"; then
  echo "Refusing to install an app with an invalid code signature: $SOURCE_APP" >&2
  exit 1
fi
if pgrep -x localvoxtral >/dev/null 2>&1; then
  echo "Refusing to replace localvoxtral while it is running." >&2
  echo "Quit the app completely, then run 'mise run install-local' again." >&2
  exit 1
fi

mkdir -p "$TARGET_DIR"
rm -rf "$TARGET_APP"
ditto "$SOURCE_APP" "$TARGET_APP"
touch "$TARGET_APP"

echo "Installed app: $TARGET_APP"
echo "Launch with: open \"$TARGET_APP\""
