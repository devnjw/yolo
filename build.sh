#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"

universal=false
case "${1:-}" in
    --universal) universal=true ;;
    --help|-h) echo 'Usage: zsh build.sh [--universal]'; exit 0 ;;
    '') ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
esac
if (( $# > 1 )); then echo 'Too many arguments' >&2; exit 2; fi
if [[ "$(uname -s)" != Darwin ]]; then echo 'Building FocusTrace requires macOS.' >&2; exit 1; fi
if ! xcrun --find swift >/dev/null 2>&1; then
    echo 'Install Xcode 16+ or Swift 6+ Command Line Tools first (xcode-select --install).' >&2
    exit 1
fi

# Universal packaging has its own output, leaving the local development app alone.
output="$PWD/dist"
if $universal; then output="$output/universal"; fi
app="$output/FocusTrace.app"
if /bin/ps -axww -o comm= | /usr/bin/grep -Fx "$app/Contents/MacOS/FocusTrace" >/dev/null; then
    echo "Quit $app before replacing it." >&2
    exit 1
fi
zsh scripts/build-icon.sh
build_args=(-c release)
if $universal; then build_args+=(--arch arm64 --arch x86_64); fi
swift build "${build_args[@]}"
bin_dir="$(swift build "${build_args[@]}" --show-bin-path)"
mkdir -p "$output"
staging="$(mktemp -d "$output/.build-app.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
bundle="$staging/FocusTrace.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$bin_dir/FocusTrace" "$bundle/Contents/MacOS/FocusTrace"
cp Resources/Info.plist "$bundle/Contents/Info.plist"
cp Resources/AppIcon.icns "$bundle/Contents/Resources/AppIcon.icns"
if $universal; then
    for architecture in arm64 x86_64; do
        xcrun lipo "$bundle/Contents/MacOS/FocusTrace" -verify_arch "$architecture"
    done
fi
identity="${SIGNING_IDENTITY:--}"
sign_args=(--force --sign "$identity" --options runtime --entitlements Resources/Entitlements.plist)
if [[ "$identity" != - ]]; then sign_args+=(--timestamp); fi
codesign "${sign_args[@]}" "$bundle"
codesign --verify --strict "$bundle"
# Only replace the previous output after a successful build and signature check.
rm -rf "$app"
mv "$bundle" "$app"
echo "$app"
