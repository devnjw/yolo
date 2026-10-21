#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
zsh scripts/build-icon.sh
swift build -c release
app="$PWD/dist/FocusTrace.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/FocusTrace "$app/Contents/MacOS/FocusTrace"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
codesign --force --sign - --options runtime --entitlements Resources/Entitlements.plist "$app"
codesign --verify --strict "$app"
echo "$app"
