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
VERSION=""  # read from the built app after the build, below

echo "==> Generating project"
xcodegen generate

echo "==> Building Release"
xcodebuild -project MakeIt3D.xcodeproj -scheme MakeIt3D -configuration Release \
  -derivedDataPath .build clean build | tail -3

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
ZIP="MakeIt3D-${VERSION}.zip"

echo "==> Checking for the two things Apple rejected last time"
# Capture first, then test. Do not pipe into `grep -q` under `set -o pipefail`:
# grep exits the moment it matches, codesign dies of SIGPIPE, and pipefail
# reports the pipeline as failed even though the match succeeded. It is timing
# dependent, so it passes by hand and fails in the script, which is the worst
# way for a check to be wrong.
SIGNING_INFO=$(codesign -dvvv "$APP" 2>&1 || true)
ENTITLEMENTS=$(codesign -d --entitlements - "$APP" 2>&1 || true)

case "$SIGNING_INFO" in
  *"Timestamp="*) echo "    secure timestamp: present" ;;
  *) echo "    secure timestamp: MISSING. Apple will reject this."; exit 1 ;;
esac

case "$ENTITLEMENTS" in
  *get-task-allow*) echo "    get-task-allow: STILL PRESENT. Apple will reject this."; exit 1 ;;
  *) echo "    get-task-allow: absent" ;;
esac

echo "==> Verifying the signature Xcode applied"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv "$APP" 2>&1 | grep -E "Authority|TeamIdentifier|flags"

echo "==> Zipping for notarization"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Submitting to Apple. This usually takes a few minutes."
SUBMIT_OUTPUT=$(xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait 2>&1)
echo "$SUBMIT_OUTPUT"

# notarytool exits 0 even when Apple rejects the build, so the status has to
# be read out of the output. Without this the script sails past a rejection
# and fails later at stapling with a CloudKit error that names the wrong
# problem entirely.
SUBMISSION_ID=$(echo "$SUBMIT_OUTPUT" | awk '/id:/ {print $2; exit}')
if ! echo "$SUBMIT_OUTPUT" | grep -q "status: Accepted"; then
  echo
  echo "Apple rejected this build. The reasons:"
  xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$PROFILE" 2>&1 \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); [print("  -", i["message"], "\n    at", i["path"]) for i in d.get("issues") or []]' \
    || echo "  (could not parse the log, run: xcrun notarytool log $SUBMISSION_ID --keychain-profile $PROFILE)"
  exit 1
fi

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
