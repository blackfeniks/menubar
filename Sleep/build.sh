#!/bin/bash
set -euo pipefail

APP="Sleepness"
DIR="$(cd "$(dirname "$0")" && pwd)"
BUNDLE="$DIR/$APP.app"
BUILD="$DIR/.build"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
TARGET="26.0"

mkdir -p "$BUILD"
echo "› Compiling (arm64, macOS $TARGET, SDK $(xcrun --sdk macosx --show-sdk-version))…"
swiftc -O \
	-target "arm64-apple-macos$TARGET" \
	-sdk "$SDK" \
	-framework SwiftUI -framework AppKit -framework ServiceManagement -framework IOKit \
	"$DIR/main.swift" "$DIR"/../shared/*.swift \
	-o "$BUILD/$APP"

echo "› Bundling and signing…"
STAGE="$BUILD/$APP.app"
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS"
cp "$DIR/Info.plist" "$STAGE/Contents/Info.plist"
cp "$BUILD/$APP" "$STAGE/Contents/MacOS/$APP"
codesign --force --deep --sign - "$STAGE"

if [[ "${1:-}" == "--run" ]]; then
	if pgrep -f "$APP.app/Contents/MacOS/$APP" >/dev/null; then
		echo "› Quitting the running copy…"
		pkill -TERM -f "$APP.app/Contents/MacOS/$APP" || true
		for _ in $(seq 1 100); do
			pgrep -f "$APP.app/Contents/MacOS/$APP" >/dev/null || break
			sleep 0.1
		done
	fi
fi

rm -rf "$BUNDLE"
mv "$STAGE" "$BUNDLE"
rm -rf "$BUILD"
echo "✓ Built $BUNDLE"

if [[ "${1:-}" == "--run" ]]; then
	open "$BUNDLE"
	echo "✓ Started"
fi
