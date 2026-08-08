#!/bin/bash
# Build, sign, notarize, staple and zip Make It 3D for a GitHub release.
#
# Prerequisites, one time:
#   xcrun notarytool store-credentials "MakeIt3D" \
#     --key /path/to/AuthKey_XXXX.p8 --key-id XXXX --issuer <issuer-uuid>
#
# That stores the App Store Connect key in your login keychain. Nothing in this
# script ever sees the key itself, only the profile name.
set -euo pipefail

PROFILE="MakeIt3D"
APP=".build/Build/Products/Release/MakeIt3D.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" MakeIt3D/Info.plist 2>/dev/null || echo "1.0.0")
ZIP="MakeIt3D-${VERSION}.zip"

echo "==> Generating project"
xcodegen generate

echo "==> Building Release"
xcodebuild -project MakeIt3D.xcodeproj -scheme MakeIt3D -configuration Release \
  -derivedDataPath .build clean build | tail -3

echo "==> Verifying the signature Xcode applied"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv "$APP" 2>&1 | grep -E "Authority|TeamIdentifier|flags"

echo "==> Zipping for notarization"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Submitting to Apple. This usually takes a few minutes."
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

echo "==> Stapling the ticket to the app"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "==> Re-zipping the stapled app"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Gatekeeper check, the thing a downloader actually hits"
spctl -a -vvv -t install "$APP"

echo
echo "Done. Attach $ZIP to the release:"
echo "  gh release create v${VERSION} $ZIP --title \"v${VERSION}\" --notes-file RELEASE_NOTES.md"
