#!/bin/zsh
#
# The stereo sign convention, measured before every build of the app.
#
# The Mac app had this inverted for a while and the rendered output still looked
# right, which is exactly why it survived. A picture with the eyes swapped is
# still a picture. So the app does not get to build unless the pixels say near
# content pops toward the viewer and far content sits behind the screen.
#
# The gate compiles the format, engine and check sources with swiftc directly
# rather than recursing into xcodebuild. One invocation, a few seconds, and no
# nested build lock.

set -euo pipefail

ROOT="${0:A:h}/.."
BUILD="$ROOT/.gate"
METAL="$ROOT/Sources/Engine/StereoWarp.metal"
TOOL="$BUILD/depthtracktool"

mkdir -p "$BUILD"

SOURCES=(
  "$ROOT"/Sources/Format/*.swift
  "$ROOT"/Sources/Engine/*.swift
  "$ROOT"/Sources/Checks/*.swift
  "$ROOT"/Tools/Gate/*.swift
)

# Skipping when nothing moved keeps an incremental app build fast. The hash
# covers the shader too, because the sign lives as much in the Metal as in the
# Swift.
STAMP="$BUILD/passed-$(cat "${SOURCES[@]}" "$METAL" | shasum -a 256 | cut -d' ' -f1)"
if [[ -f "$STAMP" ]]; then
  echo "Depth sign gate: sources unchanged since it last passed."
  exit 0
fi

setopt local_options null_glob
rm -f "$BUILD"/passed-*
unsetopt null_glob

echo "Depth sign gate: building the checker."
xcrun swiftc \
  -O \
  -swift-version 6 \
  -target arm64-apple-macos26.0 \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -o "$TOOL" \
  "${SOURCES[@]}"

echo "Depth sign gate: measuring."
"$TOOL" check-sign --metal "$METAL" --out "$BUILD/work"

touch "$STAMP"
