#!/usr/bin/env bash
# Build and install obs-mac-game-auto-capture into the local OBS instance.
#
# What it does:
#   1. Installs cmake if missing (via Homebrew).
#   2. Downloads OBS prebuilt dependencies (~200 MB) into ./.deps/obs-deps.
#   3. Clones the OBS Studio source matching your installed version into
#      ./.deps/obs-studio (only for the libobs headers — no full build).
#   4. Runs cmake configure + build.
#   5. Installs the resulting .plugin bundle into
#      ~/Library/Application Support/obs-studio/plugins/
#
# Re-run safe: skips steps whose outputs already exist.
#
# Usage:
#   chmod +x build.sh
#   ./build.sh

set -euo pipefail

cd "$(dirname "$0")"

PLUGIN_NAME="obs-mac-game-auto-capture"
OBS_VERSION="${OBS_VERSION:-32.1.2}"
OBS_DEPS_TAG="${OBS_DEPS_TAG:-2025-08-23}"
ARCH="$(uname -m)"
PLUGINS_DIR="$HOME/Library/Application Support/obs-studio/plugins"

mkdir -p .deps

echo "==> Checking build tools..."
if ! command -v brew >/dev/null 2>&1; then
    echo "Homebrew is required. Install it from https://brew.sh" >&2
    exit 1
fi
if ! command -v cmake >/dev/null 2>&1; then
    echo "Installing cmake via Homebrew..."
    brew install cmake
fi
if ! command -v xcodebuild >/dev/null 2>&1; then
    echo "xcodebuild not found. Run: xcode-select --install" >&2
    exit 1
fi

echo "==> Fetching OBS prebuilt deps (${OBS_DEPS_TAG}, ${ARCH})..."
if [ ! -d ".deps/obs-deps" ]; then
    DEPS_TARBALL="macos-deps-${OBS_DEPS_TAG}-${ARCH}.tar.xz"
    DEPS_URL="https://github.com/obsproject/obs-deps/releases/download/${OBS_DEPS_TAG}/${DEPS_TARBALL}"
    curl -fL -o ".deps/${DEPS_TARBALL}" "${DEPS_URL}"
    mkdir -p ".deps/obs-deps"
    tar -xf ".deps/${DEPS_TARBALL}" -C ".deps/obs-deps"
    rm -f ".deps/${DEPS_TARBALL}"
else
    echo "  cached at .deps/obs-deps"
fi

echo "==> Cloning OBS Studio source for headers (${OBS_VERSION})..."
if [ ! -d ".deps/obs-studio" ]; then
    git clone --depth 1 --branch "${OBS_VERSION}" \
        https://github.com/obsproject/obs-studio.git ".deps/obs-studio" \
        || {
            echo "Tag ${OBS_VERSION} not found; falling back to master."
            git clone --depth 1 https://github.com/obsproject/obs-studio.git ".deps/obs-studio"
        }
    git -C ".deps/obs-studio" submodule update --init --depth 1 --recursive libobs || true
else
    echo "  cached at .deps/obs-studio"
fi

# Resolve libobs include directory inside the cloned source.
LIBOBS_INCLUDE="$(pwd)/.deps/obs-studio/libobs"
if [ ! -f "${LIBOBS_INCLUDE}/obs-module.h" ]; then
    echo "Could not find libobs headers at ${LIBOBS_INCLUDE}" >&2
    exit 1
fi

# Resolve OBS runtime libobs framework (link target).
OBS_FRAMEWORK="/Applications/OBS.app/Contents/Frameworks/libobs.framework"
if [ ! -d "${OBS_FRAMEWORK}" ]; then
    echo "OBS.app not found at /Applications/OBS.app — install OBS first." >&2
    exit 1
fi

echo "==> Configuring..."
rm -rf build
cmake -S . -B build \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DCMAKE_OSX_ARCHITECTURES="${ARCH}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_PREFIX_PATH="$(pwd)/.deps/obs-deps" \
    -DLIBOBS_INCLUDE_DIR="${LIBOBS_INCLUDE}" \
    -DLIBOBS_LIBRARY="${OBS_FRAMEWORK}/libobs" \
    -DOBS_DEPS_INCLUDE_DIR="$(pwd)/.deps/obs-deps/include"

echo "==> Building..."
cmake --build build --config Release --parallel

echo "==> Installing to ${PLUGINS_DIR}/${PLUGIN_NAME}.plugin/"
BUNDLE="build/${PLUGIN_NAME}.plugin"
if [ ! -d "${BUNDLE}" ]; then
    echo "Build did not produce ${BUNDLE} — check build/ for errors." >&2
    exit 1
fi

# Remove any stale loose-layout install from older script versions.
rm -rf "${PLUGINS_DIR}/${PLUGIN_NAME}"
# Replace the bundle.
rm -rf "${PLUGINS_DIR}/${PLUGIN_NAME}.plugin"
mkdir -p "${PLUGINS_DIR}"
cp -R "${BUNDLE}" "${PLUGINS_DIR}/${PLUGIN_NAME}.plugin"

# Inject locale + other data files into Contents/Resources/ so obs_module_text() works.
mkdir -p "${PLUGINS_DIR}/${PLUGIN_NAME}.plugin/Contents/Resources"
cp -R data/. "${PLUGINS_DIR}/${PLUGIN_NAME}.plugin/Contents/Resources/"

echo
echo "Installed. Quit and reopen OBS, then add a source → 'Mac Game Auto Capture'."
