#!/bin/bash
set -euo pipefail

APP="Tune"
DIR="$(cd "$(dirname "$0")" && pwd)"
BUNDLE="$DIR/$APP.app"
BUILD="$DIR/.build"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
TARGET="26.0"
KC="$DIR/.signing/tune.keychain-db"
IDENTITY="Tune Local Signing"

mkdir -p "$BUILD"
echo "› Compiling (arm64, macOS $TARGET, SDK $(xcrun --sdk macosx --show-sdk-version))…"
swiftc -O -wmo \
	-target "arm64-apple-macos$TARGET" \
	-sdk "$SDK" \
	-framework AppKit -framework SwiftUI -framework CoreAudio -framework AudioToolbox \
	-framework Accelerate -framework AVFoundation \
	"$DIR"/Sources/*.swift "$DIR"/../shared/*.swift \
	-o "$BUILD/$APP"

echo "› Bundling…"
STAGE="$BUILD/$APP.app"
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$DIR/Info.plist" "$STAGE/Contents/Info.plist"
cp "$BUILD/$APP" "$STAGE/Contents/MacOS/$APP"

echo "› Signing…"
if [[ -f "$KC" ]]; then
	security unlock-keychain -p tune-local "$KC"
	ORIG_LIST="$(security list-keychains -d user | xargs)"
	restore() { eval "security list-keychains -d user -s $ORIG_LIST"; }
	trap restore EXIT
	eval "security list-keychains -d user -s $ORIG_LIST \"$KC\""
	codesign --force --timestamp=none -s "$IDENTITY" -i com.ilya.tune "$STAGE"
	restore
	trap - EXIT
else
	echo "  (no .signing keychain — ad-hoc signature: macOS will ask for the permission again after each build)"
	codesign --force --timestamp=none -s - "$STAGE"
fi

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
