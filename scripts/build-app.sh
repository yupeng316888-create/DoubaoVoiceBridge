#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
cd "$project_root"

swift build -c release --arch x86_64 -j 2
swift build -c release --arch arm64 -j 2

stage_root="$(mktemp -d "${TMPDIR:-/tmp}/doubao-voice-bridge.XXXXXX")"
trap 'rm -rf "$stage_root"' EXIT

stage_app="$stage_root/远控听写·自动适配.app"
mkdir -p "$stage_app/Contents/MacOS" "$stage_app/Contents/Resources"
cp "$project_root/Resources/Info.plist" "$stage_app/Contents/Info.plist"
cp "$project_root/Resources/AppIcon.icns" "$stage_app/Contents/Resources/AppIcon.icns"
cp "$project_root/LICENSE" "$stage_app/Contents/Resources/LICENSE"

lipo -create \
    "$project_root/.build/x86_64-apple-macosx/release/DoubaoVoiceBridge" \
    "$project_root/.build/arm64-apple-macosx/release/DoubaoVoiceBridge" \
    -output "$stage_app/Contents/MacOS/DoubaoVoiceBridge"
chmod 755 "$stage_app/Contents/MacOS/DoubaoVoiceBridge"

codesign --force --sign - \
    --identifier com.lyp.DoubaoVoiceBridge \
    --requirements '=designated => identifier "com.lyp.DoubaoVoiceBridge"' \
    "$stage_app"

mkdir -p "$project_root/dist"
output_app="$project_root/dist/远控听写·自动适配.app"
if [[ -e "$output_app" ]]; then
    rm -rf "$output_app"
fi
ditto "$stage_app" "$output_app"

codesign --verify --deep --strict --verbose=2 "$output_app"
file "$output_app/Contents/MacOS/DoubaoVoiceBridge"
"$output_app/Contents/MacOS/DoubaoVoiceBridge" --self-test
"$output_app/Contents/MacOS/DoubaoVoiceBridge" --diagnostics
