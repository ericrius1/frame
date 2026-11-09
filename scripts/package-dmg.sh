#!/bin/bash
# Build a universal (Apple silicon + Intel) Frame.app and wrap it in a
# drag-to-Applications DMG at dist/Frame-<version>.dmg.
#
# Signing: set FRAME_SIGNING_IDENTITY to a code-signing certificate's SHA-1
# fingerprint (see `security find-identity -v -p codesigning`). A Developer ID
# Application certificate plus FRAME_NOTARY_PROFILE (a `notarytool
# store-credentials` profile name) produces a notarized, stapled DMG that opens
# without any Gatekeeper prompt. Without an identity the app is ad-hoc signed.
set -euo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
dist_dir="$project_dir/dist"
stage_dir="$project_dir/.build/dmg-stage"
app="$stage_dir/Frame.app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$project_dir/Resources/Info.plist")"
dmg="$dist_dir/Frame-$version.dmg"
identity="${FRAME_SIGNING_IDENTITY:--}"

swift build --configuration release --arch arm64 --arch x86_64 --package-path "$project_dir"
bin_dir="$(swift build --configuration release --arch arm64 --arch x86_64 --package-path "$project_dir" --show-bin-path)"

rm -rf "$stage_dir"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$dist_dir"
cp "$bin_dir/Frame" "$app/Contents/MacOS/Frame"
cp "$project_dir/Resources/Info.plist" "$app/Contents/Info.plist"
cp "$project_dir/Resources/Frame.icns" "$app/Contents/Resources/Frame.icns"
plutil -lint "$app/Contents/Info.plist"

sign_args=(--force --sign "$identity" --identifier dev.frame.capture
           --entitlements "$project_dir/Resources/Frame.entitlements")
[[ "$identity" != "-" ]] && sign_args+=(--options runtime --timestamp)
codesign "${sign_args[@]}" "$app"
codesign --verify --deep --strict "$app"
lipo -info "$app/Contents/MacOS/Frame"

ln -s /Applications "$stage_dir/Applications"
rm -f "$dmg"
hdiutil create -volname "Frame $version" -srcfolder "$stage_dir" -fs HFS+ \
    -format UDZO -imagekey zlib-level=9 -ov "$dmg"
[[ "$identity" != "-" ]] && codesign --force --sign "$identity" --timestamp "$dmg"

if [[ -n "${FRAME_NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$dmg" --keychain-profile "$FRAME_NOTARY_PROFILE" --wait
    xcrun stapler staple "$dmg"
fi

# Remove the staged bundle so LaunchServices never sees a second Frame.app.
rm -rf "$stage_dir"

hdiutil verify "$dmg"
shasum -a 256 "$dmg"
printf 'Built %s\n' "$dmg"
