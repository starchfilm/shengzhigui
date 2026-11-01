#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"

task_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
task_dmg_name="ShengZhiGui-${task_version}-universal.dmg"
task_stage="$(mktemp -d "${TMPDIR:-/tmp/}shengzhigui-dmg.XXXXXX")"
trap 'rm -rf "$task_stage"' EXIT

# Build in an isolated staging directory; do not replace the running local app.
SOUNDCHANNELS_APP_PATH="$task_stage/声之轨.app" zsh Scripts/build-app.sh --universal
lipo "$task_stage/声之轨.app/Contents/MacOS/SoundChannels" -verify_arch arm64 x86_64
ln -s /Applications "$task_stage/Applications"
cat > "$task_stage/安装说明.txt" <<'TEXT'
声之轨 — 安装说明

1. 将“声之轨.app”拖到 Applications（应用程序）。
2. 从“应用程序”打开声之轨，点击菜单栏中的扬声器图标。
3. 展开“应用音量”，开启要控制的应用；首次开启时允许系统音频录制。

这是早期测试版，支持 macOS 14.2 及以上，包含 Apple Silicon 和 Intel 两种架构。
主要验证环境为 Apple Silicon、macOS 26.4；Intel 与其他硬件组合仍需实测。

本版本使用临时签名，未经 Apple Developer ID 签名和公证。
macOS 可能阻止首次打开。请仅从项目官方 GitHub Release 获取安装包，
核对校验值，并参考苹果的打开应用说明：
https://support.apple.com/102445

通话音量保护只作用于已开启音频控制的应用。
音频只在本机处理，不保存或上传；不采集麦克风或屏幕画面。

源码、说明与 MIT 许可证：
https://github.com/starchfilm/shengzhigui
TEXT

mkdir -p dist
hdiutil create -ov -volname "声之轨 ${task_version}" -srcfolder "$task_stage" -fs HFS+ -format UDZO "dist/$task_dmg_name"
hdiutil verify "dist/$task_dmg_name"
(cd dist && shasum -a 256 "$task_dmg_name" > "$task_dmg_name.sha256")
echo "$PWD/dist/$task_dmg_name"
