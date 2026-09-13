#!/bin/bash
# Build a local, runnable ThermalForge.app without an Apple Developer account.
# The result is ad hoc signed for this Mac and is intended for local use only.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

CONFIGURATION="${CONFIGURATION:-release}"
DEST_DIR="${DEST_DIR:-$ROOT_DIR/dist}"
APP_PATH="$DEST_DIR/ThermalForge.app"

echo "Building ThermalForge ($CONFIGURATION)..."
swift build -c "$CONFIGURATION" --quiet
BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"

ICON_PATH="$ROOT_DIR/ThermalForge.icns"
if [[ ! -f "$ICON_PATH" ]]; then
    command -v iconutil >/dev/null 2>&1 || {
        echo "iconutil is required to generate ThermalForge.icns on macOS." >&2
        exit 1
    }
    echo "Generating app icon..."
    swift Scripts/generate-icon.swift
    iconutil -c icns ThermalForge.iconset -o "$ICON_PATH"
fi

rm -rf "$DEST_DIR"
mkdir -p "$DEST_DIR"

"$BIN_DIR/thermalforge" build-app \
    --binary "$BIN_DIR/ThermalForgeApp" \
    --icon "$ICON_PATH" \
    --cli "$BIN_DIR/thermalforge" \
    --dest "$APP_PATH"

# Ad hoc signing avoids a Developer ID requirement and lets macOS launch the
# locally-built bundle. It does not provide distribution trust or notarization.
xattr -c "$APP_PATH" 2>/dev/null || true
codesign --force --sign - --timestamp=none "$APP_PATH"

cp "$BIN_DIR/thermalforge" "$DEST_DIR/thermalforge"

echo
echo "Built: $APP_PATH"
echo "CLI:   $DEST_DIR/thermalforge"
echo "Run:   open \"$APP_PATH\""
