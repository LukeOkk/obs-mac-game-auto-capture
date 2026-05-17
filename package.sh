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

# A double-clickable installer script. It uses $HOME so it resolves to the
# user's own home directory at click time — no hard-coded paths.
cat > "$DMG_STAGE/Install.command" <<'INSTALLER'
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BUNDLE="$HERE/obs-mac-game-auto-capture.plugin"
DEST="$HOME/Library/Application Support/obs-studio/plugins"

if [ ! -d "$BUNDLE" ]; then
    osascript -e 'display alert "Plugin bundle missing" message "obs-mac-game-auto-capture.plugin was not found next to this installer." as critical'
    exit 1
fi

mkdir -p "$DEST"
# Replace any prior install (both bundle layout and the legacy loose layout
# from very early versions).
rm -rf "$DEST/obs-mac-game-auto-capture.plugin"
rm -rf "$DEST/obs-mac-game-auto-capture"
cp -R "$BUNDLE" "$DEST/obs-mac-game-auto-capture.plugin"

osascript -e 'display alert "Plugin installed" message "Quit OBS Studio if it is running, then open it again. Add a source → Mac Game Auto Capture." buttons {"OK"} default button "OK"'
INSTALLER
chmod +x "$DMG_STAGE/Install.command"

cat > "$DMG_STAGE/INSTALL.txt" <<EOF
${DISPLAY_NAME} ${VERSION}

To install:
  1. Double-click "Install.command".
  2. macOS may ask whether to allow it — open System Settings → Privacy &
     Security and click "Open Anyway" if needed.
  3. Quit OBS Studio if it is running, then open it again.
  4. Add a source → "${DISPLAY_NAME}".

Manual alternative:
  Copy "${PLUGIN_NAME}.plugin" to
    ~/Library/Application Support/obs-studio/plugins/
  Then restart OBS.

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
