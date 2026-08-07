#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

SOURCE_APP="$ROOT_DIR/dist/localvoxtral.app"
TARGET_DIR="$HOME/Applications"
TARGET_APP="$TARGET_DIR/localvoxtral.app"

if [[ ! -d "$SOURCE_APP" ]]; then
  echo "Missing packaged app: $SOURCE_APP"
  echo "Run 'mise run package' first."
  exit 1
fi

mkdir -p "$TARGET_DIR"
rm -rf "$TARGET_APP"
ditto "$SOURCE_APP" "$TARGET_APP"
touch "$TARGET_APP"

echo "Installed app: $TARGET_APP"
echo "Launch with: open \"$TARGET_APP\""
