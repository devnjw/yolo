#!/bin/zsh
# Build a data-free, universal drag-to-install disk image for sharing.
set -euo pipefail
cd "${0:A:h:h}"
case "${1:-}" in
    --help|-h) echo 'Usage: [SIGNING_IDENTITY="Developer ID Application: …" NOTARY_PROFILE=…] zsh scripts/package.sh'; exit 0 ;;
    '') ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
esac
if (( $# > 1 )); then echo 'Too many arguments' >&2; exit 2; fi
if [[ -n "${NOTARY_PROFILE:-}" && "${SIGNING_IDENTITY:--}" == - ]]; then
    echo 'NOTARY_PROFILE requires a Developer ID Application SIGNING_IDENTITY.' >&2
    exit 1
fi

zsh build.sh --universal
app="$PWD/dist/universal/FocusTrace.app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")"
name="FocusTrace-${version}-${build}-universal"
work="$(mktemp -d "$PWD/dist/.package.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# Submit a ZIP of the app first so the installed app itself carries a ticket.
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    ditto -c -k --keepParent "$app" "$work/notarization.zip"
    xcrun notarytool submit "$work/notarization.zip" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$app"
    xcrun stapler validate "$app"
    spctl --assess --type execute --verbose=2 "$app"
    notice='Developer ID signed and notarized by Apple.'
else
    notice='Not notarized by Apple. See Install FocusTrace.txt for first-launch instructions.'
fi
mkdir "$work/image"
# Explicit allowlist: never include the working tree, user preferences, or usage data.
ditto "$app" "$work/image/FocusTrace.app"
ln -s /Applications "$work/image/Applications"
cp docs/INSTALL.txt "$work/image/Install FocusTrace.txt"
printf 'FocusTrace %s (%s)\n%s\n' "$version" "$build" "$notice" > "$work/image/Build info.txt"
hdiutil create -volname FocusTrace -srcfolder "$work/image" -format UDZO "$work/$name.dmg"
if [[ "${SIGNING_IDENTITY:--}" != - ]]; then
    codesign --sign "$SIGNING_IDENTITY" --timestamp "$work/$name.dmg"
    codesign --verify --strict "$work/$name.dmg"
fi
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$work/$name.dmg" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$work/$name.dmg"
    xcrun stapler validate "$work/$name.dmg"
fi
hdiutil verify "$work/$name.dmg"
mv -f "$work/$name.dmg" "dist/$name.dmg"
(cd dist && shasum -a 256 "$name.dmg" > "$name.dmg.sha256")
printf '\nReady to share: %s\n%s\n' "$PWD/dist/$name.dmg" "$notice"
