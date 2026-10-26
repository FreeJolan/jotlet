#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
task_universal=false
if [[ "${1:-}" == --universal && $# == 1 ]]; then
    task_universal=true
elif (( $# > 0 )); then
    print -u2 "Usage: $0 [--universal]"
    exit 2
fi
if $task_universal; then
    swift build -c release --arch arm64
    swift build -c release --arch x86_64
    task_arm="$(swift build -c release --arch arm64 --show-bin-path)/Jotlet"
    task_intel="$(swift build -c release --arch x86_64 --show-bin-path)/Jotlet"
else
    swift build -c release
    task_binary="$(swift build -c release --show-bin-path)/Jotlet"
fi
task_app="$PWD/dist/Jotlet.app"
# Assemble a fresh bundle so old resources cannot leak into a release.
rm -rf "$task_app"
mkdir -p "$task_app/Contents/MacOS" "$task_app/Contents/Resources"
if $task_universal; then
    lipo -create "$task_arm" "$task_intel" -output "$task_app/Contents/MacOS/Jotlet"
else
    cp "$task_binary" "$task_app/Contents/MacOS/Jotlet"
fi
cp packaging/Info.plist "$task_app/Contents/Info.plist"
cp assets/AppIcon.png .build/icon.png
mkdir -p .build/Jotlet.iconset
for task_size in 16 32 128 256 512; do
    sips -z "$task_size" "$task_size" .build/icon.png --out ".build/Jotlet.iconset/icon_${task_size}x${task_size}.png" >/dev/null
    task_retina=$((task_size * 2))
    sips -z "$task_retina" "$task_retina" .build/icon.png --out ".build/Jotlet.iconset/icon_${task_size}x${task_size}@2x.png" >/dev/null
done
iconutil -c icns .build/Jotlet.iconset -o "$task_app/Contents/Resources/Jotlet.icns"
codesign --force --sign - "$task_app"
codesign --verify --deep --strict "$task_app"
print "Built $task_app"
