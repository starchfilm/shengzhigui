#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
swift build -c release
APP="$PWD/dist/声之轨.app"
mkdir -p "$APP/Contents/MacOS"
BIN_DIR="$(swift build -c release --show-bin-path)"
cp "$BIN_DIR/SoundChannels" "$APP/Contents/MacOS/SoundChannels"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - --identifier com.starchfilm.SoundChannels "$APP"
echo "$APP"
