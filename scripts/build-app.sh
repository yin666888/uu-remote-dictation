#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
cd "$project_root"
stage_root="$(mktemp -d "${TMPDIR:-/tmp}/doubao-voice-bridge.XXXXXX")"
trap 'rm -rf "$stage_root"' EXIT

# Swift can use either the native SwiftPM layout or Xcode's shared Products
# directory. Ask Swift for the path and preserve each architecture immediately.
for architecture in x86_64 arm64; do
    swift build -c release --arch "$architecture" -j 2
    binary_dir="$(swift build -c release --arch "$architecture" --show-bin-path)"
    cp "$binary_dir/DoubaoVoiceBridge" "$stage_root/$architecture"
done
lipo -create "$stage_root/x86_64" "$stage_root/arm64" -output "$stage_root/DoubaoVoiceBridge"
strip -S "$stage_root/DoubaoVoiceBridge"
mkdir -p "$project_root/dist"

for role in sender receiver; do
    app_name="远控听写"
    identifier="org.remotedictation.bridge"
    if [[ "$role" == receiver ]]; then
        app_name="远控直输接收端"
        identifier="org.remotedictation.bridge.Receiver"
    fi
    stage_app="$stage_root/$app_name.app"
    mkdir -p "$stage_app/Contents/MacOS" "$stage_app/Contents/Resources"
    cp "$project_root/Resources/Info.plist" "$stage_app/Contents/Info.plist"
    cp "$stage_root/DoubaoVoiceBridge" "$stage_app/Contents/MacOS/DoubaoVoiceBridge"
    chmod 755 "$stage_app/Contents/MacOS/DoubaoVoiceBridge"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $identifier" "$stage_app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName $app_name" "$stage_app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $app_name" "$stage_app/Contents/Info.plist"
    if [[ "$role" == receiver ]]; then
        /usr/libexec/PlistBuddy -c 'Add :DirectInputReceiver bool true' "$stage_app/Contents/Info.plist"
    fi
    codesign --force --sign - --identifier "$identifier" \
        --requirements "=designated => identifier \"$identifier\"" "$stage_app"
    codesign --verify --deep --strict --verbose=2 "$stage_app"
    "$stage_app/Contents/MacOS/DoubaoVoiceBridge" --self-test
    output_app="$project_root/dist/$app_name.app"
    if [[ -e "$output_app" ]]; then rm -rf "$output_app"; fi
    ditto "$stage_app" "$output_app"
done
file "$project_root/dist/远控听写.app/Contents/MacOS/DoubaoVoiceBridge"
