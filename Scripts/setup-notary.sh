#!/bin/bash
# One time notarization setup. Run this yourself, once, per machine.
#
# Everything you type here goes from your terminal straight into the macOS
# keychain. Nothing is written to this repo, to a dotfile, or to your shell
# history, and no agent ever sees it. After this runs, every other script in
# Scripts/ refers to the credential by the profile name alone.
#
#   ./Scripts/setup-notary.sh
#
set -euo pipefail

PROFILE="${1:-MakeIt3D}"
TEAM_ID="8J4SDPB6A2"

echo
echo "Notarization setup for profile: $PROFILE"
echo

if xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  echo "A profile named '$PROFILE' already exists and works. Nothing to do."
  echo "To replace it, run again and answer y below."
  read -r -p "Replace it? [y/N] " replace
  [[ "$replace" =~ ^[Yy]$ ]] || exit 0
fi

echo "Two ways to authenticate. Both work identically for notarization."
echo
echo "  1) App Store Connect API key   (a .p8 file, plus a Key ID and Issuer ID)"
echo "  2) App specific password       (generated at appleid.apple.com, quicker)"
echo
read -r -p "Which? [1/2] " method
echo

if [ "$method" = "1" ]; then
  # -e gives readline, so tab completion works on the path.
  read -r -e -p "Path to your .p8 file: " KEY_PATH
  KEY_PATH="${KEY_PATH/#\~/$HOME}"
  if [ ! -f "$KEY_PATH" ]; then
    echo "No file at that path. Nothing was stored."
    exit 1
  fi
  read -r -p "Key ID (10 characters, next to the key in App Store Connect): " KEY_ID
  read -r -p "Issuer ID (a UUID, at the top of the Keys page): " ISSUER_ID

  xcrun notarytool store-credentials "$PROFILE" \
    --key "$KEY_PATH" --key-id "$KEY_ID" --issuer "$ISSUER_ID"

elif [ "$method" = "2" ]; then
  read -r -p "Apple ID email: " APPLE_ID
  echo "Paste the app specific password. It will not be echoed."
  read -r -s APP_PASSWORD
  echo

  xcrun notarytool store-credentials "$PROFILE" \
    --apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$APP_PASSWORD"
  unset APP_PASSWORD

else
  echo "Pick 1 or 2."
  exit 1
fi

echo
echo "==> Verifying"
if xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  echo "Stored and working. Run ./Scripts/release.sh when you are ready to ship."
else
  echo "Stored, but the check failed. Usually a wrong Key ID or Issuer ID."
  exit 1
fi
