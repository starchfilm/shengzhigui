#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
APP="${SOUNDCHANNELS_APP_PATH:-$PWD/dist/声之轨.app}"
mkdir -p "$APP/Contents/MacOS"
if [[ "${1:-}" == "--universal" ]]; then
    task_bins=()
    for task_arch in arm64 x86_64; do
        task_triple="${task_arch}-apple-macosx14.2"
        swift build -c release --triple "$task_triple"
        BIN_DIR="$(swift build -c release --triple "$task_triple" --show-bin-path)"
        task_bins+=("$BIN_DIR/SoundChannels")
    done
    lipo -create "${task_bins[@]}" -output "$APP/Contents/MacOS/SoundChannels"
elif [[ $# == 0 ]]; then
    swift build -c release
    BIN_DIR="$(swift build -c release --show-bin-path)"
    cp "$BIN_DIR/SoundChannels" "$APP/Contents/MacOS/SoundChannels"
else
    echo "Usage: zsh Scripts/build-app.sh [--universal]" >&2
    exit 1
fi
mkdir -p "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp LICENSE "$APP/Contents/Resources/LICENSE"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - --identifier com.starchfilm.SoundChannels "$APP"
codesign --verify --strict "$APP"
echo "$APP"
