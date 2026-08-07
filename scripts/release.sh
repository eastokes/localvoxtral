#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if ! command -v mise >/dev/null 2>&1; then
  echo "Missing required command: mise"
  echo "Install it with 'brew install mise', then run 'mise trust' from repo root."
  exit 1
fi

TAG="${1:-}"
if [[ -z "$TAG" ]]; then
  echo "Usage: ./scripts/release.sh v0.3.0"
  exit 1
fi

if [[ ! "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
  echo "Invalid tag: $TAG"
  echo "Expected semantic tag like v0.3.0"
  exit 1
fi

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Working tree is not clean. Commit or stash changes first."
  exit 1
fi

CURRENT_BRANCH="$(git branch --show-current)"
if [[ "$CURRENT_BRANCH" != "main" ]]; then
  echo "Release must run from main. Current branch: $CURRENT_BRANCH"
  exit 1
fi

if ! git remote get-url origin >/dev/null 2>&1; then
  echo "Missing origin remote."
  exit 1
fi

if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  echo "Tag already exists locally: $TAG"
  exit 1
fi

if git ls-remote --tags origin "refs/tags/$TAG" | grep -q .; then
  echo "Tag already exists on origin: $TAG"
  exit 1
fi

VERSION="${TAG#v}"
ARCHIVE_PATH="dist/localvoxtral-${TAG}.zip"
DMG_PATH="dist/localvoxtral-${TAG}.dmg"

echo "Running build and tests..."
mise run build
mise run test

echo "Packaging app..."
APP_VERSION="$VERSION" BUILD_NUMBER=1 mise run package

echo "Creating archive $ARCHIVE_PATH..."
mkdir -p dist
rm -f "$ARCHIVE_PATH"
ditto -c -k --sequesterRsrc --keepParent "dist/localvoxtral.app" "$ARCHIVE_PATH"

echo "Creating disk image $DMG_PATH..."
rm -f "$DMG_PATH"
DMG_STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/localvoxtral-dmg.XXXXXX")"
trap 'rm -rf "$DMG_STAGING_DIR"' EXIT
cp -R "dist/localvoxtral.app" "$DMG_STAGING_DIR/localvoxtral.app"
ln -s /Applications "$DMG_STAGING_DIR/Applications"
hdiutil create -volname "localvoxtral" -srcfolder "$DMG_STAGING_DIR" -ov -format UDZO "$DMG_PATH"

echo "Pushing main..."
git push origin main

echo "Tagging and pushing $TAG..."
git tag -a "$TAG" -m "Release $TAG"
git push origin "$TAG"

echo "Published $TAG"
echo "GitHub Actions will build and publish the release artifact from this tag."
echo "Release page: https://github.com/T0mSIlver/localvoxtral/releases/tag/$TAG"
