#!/usr/bin/env bash
# Package the built plugin into distributable artifacts:
#   dist/obs-mac-game-auto-capture-<VERSION>-<ARCH>.zip   (plain bundle)
#   dist/obs-mac-game-auto-capture-<VERSION>-<ARCH>.dmg   (drag-to-install)
#
# Reads VERSION from buildspec.json. Runs build.sh first if the .plugin
# bundle isn't already built.
#
# Usage:
#   chmod +x package.sh
#   ./package.sh
#
# Output goes to ./dist/ which is gitignored.

set -euo pipefail
cd "$(dirname "$0")"

PLUGIN_NAME="obs-mac-game-auto-capture"
DISPLAY_NAME="Mac Game Auto Capture"
ARCH="$(uname -m)"
# Parse the plugin's top-level "version" (the obs-studio dependency also has
# a "version" field, so we use Python's json module to read the right one).
VERSION="$(/usr/bin/python3 -c "import json,sys; print(json.load(open('buildspec.json'))['version'])" 2>/dev/null || echo "dev")"

BUNDLE="build/${PLUGIN_NAME}.plugin"
if [ ! -d "$BUNDLE" ]; then
    echo "==> Bundle not built — running build.sh first"
    ./build.sh
fi

if [ ! -d "$BUNDLE" ]; then
    echo "Build did not produce ${BUNDLE}." >&2
    exit 1
fi

# Ensure data/ is inside the bundle (build.sh already does this on install,
# but the local build/ copy is bare unless we inject it now).
mkdir -p "${BUNDLE}/Contents/Resources"
cp -R data/. "${BUNDLE}/Contents/Resources/"

mkdir -p dist
ARTIFACT_BASE="${PLUGIN_NAME}-${VERSION}-${ARCH}"
ZIP_PATH="dist/${ARTIFACT_BASE}.zip"
DMG_PATH="dist/${ARTIFACT_BASE}.dmg"

# Clean previous artifacts for this version.
rm -f "$ZIP_PATH" "$DMG_PATH"

echo "==> Creating ${ZIP_PATH}"
( cd build && /usr/bin/ditto -c -k --keepParent "${PLUGIN_NAME}.plugin" "../${ZIP_PATH}" )

echo "==> Creating ${DMG_PATH}"
DMG_STAGE="$(mktemp -d)/dmg-stage"
mkdir -p "$DMG_STAGE"
cp -R "$BUNDLE" "$DMG_STAGE/"
# Add a symlink so user can drag the .plugin straight into the OBS plugins dir.
ln -s "$HOME/Library/Application Support/obs-studio/plugins" "$DMG_STAGE/Drag plugin here"
# Add a short README inside the dmg.
cat > "$DMG_STAGE/INSTALL.txt" <<EOF
${DISPLAY_NAME} ${VERSION}

To install:
  1. Drag "${PLUGIN_NAME}.plugin" onto the "Drag plugin here" alias.
  2. Quit OBS if it's running, then open it again.
  3. Add a source → "${DISPLAY_NAME}".

If macOS warns the plugin is from an unidentified developer:
  System Settings → Privacy & Security → scroll down to the warning
  about the plugin → click "Open Anyway".

Requirements: macOS 14+, OBS Studio 30+, Apple Silicon.
EOF

hdiutil create \
    -volname "${DISPLAY_NAME} ${VERSION}" \
    -srcfolder "$DMG_STAGE" \
    -ov -format UDZO \
    "$DMG_PATH" >/dev/null

rm -rf "$(dirname "$DMG_STAGE")"

echo
echo "Artifacts:"
ls -lh "$ZIP_PATH" "$DMG_PATH"
echo
echo "Upload these to a GitHub Release. The .zip is suitable for users who"
echo "prefer manual install; the .dmg is drag-to-install."
