#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
cd "$project_root"
swift build -c release --arch arm64 -j 2
app_binary="$project_root/.build/arm64-apple-macosx/release/DoubaoVoiceBridge"
"$app_binary" --self-test
stage_root="$(mktemp -d "${TMPDIR:-/tmp}/uu-fn-voice.XXXXXX")"
trap 'rm -rf "$stage_root"' EXIT
stage_app="$stage_root/UU-Fn-Voice.app"
mkdir -p "$stage_app/Contents/MacOS" "$stage_app/Contents/Resources"
cp "$project_root/Resources/Info.plist" "$stage_app/Contents/Info.plist"
cp "$app_binary" "$stage_app/Contents/MacOS/DoubaoVoiceBridge"
chmod 755 "$stage_app/Contents/MacOS/DoubaoVoiceBridge"
codesign --force --sign - --identifier com.example.DoubaoVoiceBridge.Fn \
  --requirements '=designated => identifier "com.example.DoubaoVoiceBridge.Fn"' "$stage_app"
codesign --verify --deep --strict "$stage_app"
mkdir -p "$project_root/dist"
output_app="$project_root/dist/UU-Fn-Voice.app"
if [[ -e "$output_app" ]]; then
    rm -rf "$output_app"
fi
ditto "$stage_app" "$output_app"
codesign --verify --deep --strict "$output_app"
ditto -c -k --keepParent "$project_root/dist/UU-Fn-Voice.app" "$project_root/dist/UU-Fn-Voice.zip"
echo "FN_APP_READY=$project_root/dist/UU-Fn-Voice.app"
