#!/bin/bash
set -euo pipefail

APP="Translator"
DIR="$(cd "$(dirname "$0")" && pwd)"
BUNDLE="$DIR/$APP.app"
BUILD="$DIR/.build"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
TARGET="26.0"

LLAMA_FW_DIR="$DIR/Vendor"
KC="$DIR/.signing/diktovka.keychain-db"
IDENTITY="Diktovka Local Signing"

mkdir -p "$BUILD"
echo "› Compiling (arm64, macOS $TARGET, SDK $(xcrun --sdk macosx --show-sdk-version))…"
swiftc -O -wmo \
	-target "arm64-apple-macos$TARGET" \
	-sdk "$SDK" \
	-F "$LLAMA_FW_DIR" \
	-framework AppKit -framework SwiftUI -framework ApplicationServices -framework Carbon -framework ServiceManagement \
	-framework Vision -framework Accelerate -framework llama \
	"$DIR"/Sources/*.swift "$DIR"/../shared/*.swift \
	-Xlinker -rpath -Xlinker @executable_path/../Frameworks \
	-o "$BUILD/$APP"

echo "› Bundling…"
STAGE="$BUILD/$APP.app"
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources" "$STAGE/Contents/Frameworks"
cp "$DIR/Info.plist" "$STAGE/Contents/Info.plist"
cp "$BUILD/$APP" "$STAGE/Contents/MacOS/$APP"
ditto "$LLAMA_FW_DIR/llama.framework" "$STAGE/Contents/Frameworks/llama.framework"
rm -rf "$STAGE/Contents/Frameworks/llama.framework/Versions/A/Headers" \
	"$STAGE/Contents/Frameworks/llama.framework/Headers" \
	"$STAGE/Contents/Frameworks/llama.framework/Versions/A/Modules" \
	"$STAGE/Contents/Frameworks/llama.framework/Modules"

echo "› Signing…"
sign() { codesign --force --timestamp=none "$@"; }
if [[ -f "$KC" ]]; then
	security unlock-keychain -p diktovka-local "$KC"
	ORIG_LIST="$(security list-keychains -d user | xargs)"
	restore() { eval "security list-keychains -d user -s $ORIG_LIST"; }
	trap restore EXIT
	eval "security list-keychains -d user -s $ORIG_LIST \"$KC\""
	sign -s "$IDENTITY" "$STAGE/Contents/Frameworks/llama.framework"
	sign -s "$IDENTITY" -i com.ilya.translator "$STAGE"
	restore
	trap - EXIT
else
	echo "  (no .signing keychain — ad-hoc signature: macOS will ask for permissions again after each build)"
	sign -s - "$STAGE/Contents/Frameworks/llama.framework"
	sign -s - "$STAGE"
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
