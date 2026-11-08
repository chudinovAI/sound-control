#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export MACOSX_DEPLOYMENT_TARGET=14.2
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
APP="$(pwd)/build/Sound Control.app"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/SoundControl" "$APP/Contents/MacOS/SoundControl"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
printf '\nApplication built: %s\n' "$APP"
