#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
task_dir="$(mktemp -d "${TMPDIR:-/tmp/}shengzhigui-icon.XXXXXX")"
trap 'rm -rf "$task_dir"' EXIT
task_iconset="$task_dir/AppIcon.iconset"
mkdir -p "$task_iconset"
for task_size in 16 32 128 256 512; do
    sips -z "$task_size" "$task_size" Resources/AppIcon.png --out "$task_iconset/icon_${task_size}x${task_size}.png" >/dev/null
    task_retina=$((task_size * 2))
    sips -z "$task_retina" "$task_retina" Resources/AppIcon.png --out "$task_iconset/icon_${task_size}x${task_size}@2x.png" >/dev/null
done
iconutil -c icns "$task_iconset" -o Resources/AppIcon.icns
