#!/bin/bash
# Build, sign, notarize and package MeetingsAlert for distribution.
# Works with Xcode Command Line Tools only - full Xcode is not required.
#
#   ./scripts/release.sh                    build + sign + notarize + staple + dmg
#   ./scripts/release.sh --no-notarize      build + sign + dmg only (local testing)
#   ./scripts/release.sh --publish v1.1.0   ...and upload it to a GitHub release
#
# One-time setup for notarization (stores credentials in the login keychain):
#   xcrun notarytool store-credentials MeetingsAlertNotary \
#     --apple-id <your-apple-id> --team-id RLVYQT69D4 --password <app-specific-password>
# App-specific passwords come from https://account.apple.com -> Sign-In and Security.

set -euo pipefail

APP_NAME="MeetingsAlert"
BUNDLE_ID="com.meetingsalert.app"
MARKETING_VERSION="1.1.1"
BUILD_VERSION="3"
DEPLOYMENT_TARGET="13.0"
SIGN_IDENTITY="Developer ID Application: Anand Hrushikesh (RLVYQT69D4)"
NOTARY_PROFILE="MeetingsAlertNotary"

REPO="and/meeting-alerts-mac"

NOTARIZE=1
PUBLISH_TAG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-notarize) NOTARIZE=0; shift ;;
    --publish)     PUBLISH_TAG="${2:-}"; shift 2 || true ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

if [[ -n "$PUBLISH_TAG" ]]; then
  [[ $NOTARIZE -eq 1 ]] || { echo "ERROR: refusing to publish an unnotarized build." >&2; exit 2; }
  [[ "$PUBLISH_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "ERROR: tag must look like v1.2.3, got '$PUBLISH_TAG'" >&2; exit 2; }
  command -v gh >/dev/null || { echo "ERROR: gh CLI not installed (brew install gh)." >&2; exit 2; }
  gh auth status >/dev/null 2>&1 || { echo "ERROR: gh not authenticated (gh auth login)." >&2; exit 2; }
  if gh release view "$PUBLISH_TAG" -R "$REPO" >/dev/null 2>&1; then
    echo "ERROR: release $PUBLISH_TAG already exists on $REPO. Bump the version." >&2
    exit 2
  fi
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/$APP_NAME"
BUILD="$ROOT/build"
APP="$BUILD/$APP_NAME.app"
DMG="$BUILD/$APP_NAME.dmg"   # promoted to $ROOT only once the full pipeline succeeds

rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

SDK="$(xcrun --show-sdk-path)"

# --- compile a universal binary -------------------------------------------
for ARCH in arm64 x86_64; do
  echo "==> compiling $ARCH"
  swiftc -O -whole-module-optimization \
    -sdk "$SDK" -target "$ARCH-apple-macos$DEPLOYMENT_TARGET" \
    -o "$BUILD/$APP_NAME-$ARCH" \
    "$SRC"/*.swift
done
lipo -create -output "$APP/Contents/MacOS/$APP_NAME" \
  "$BUILD/$APP_NAME-arm64" "$BUILD/$APP_NAME-x86_64"
rm -f "$BUILD/$APP_NAME-arm64" "$BUILD/$APP_NAME-x86_64"

# --- assemble the bundle ---------------------------------------------------
# Info.plist in the source tree uses Xcode $(VAR) placeholders; expand them.
sed -e "s|\$(DEVELOPMENT_LANGUAGE)|en|g" \
    -e "s|\$(EXECUTABLE_NAME)|$APP_NAME|g" \
    -e "s|\$(PRODUCT_BUNDLE_IDENTIFIER)|$BUNDLE_ID|g" \
    -e "s|\$(PRODUCT_NAME)|$APP_NAME|g" \
    -e "s|\$(PRODUCT_BUNDLE_PACKAGE_TYPE)|APPL|g" \
    -e "s|\$(MARKETING_VERSION)|$MARKETING_VERSION|g" \
    -e "s|\$(CURRENT_PROJECT_VERSION)|$BUILD_VERSION|g" \
    -e "s|\$(MACOSX_DEPLOYMENT_TARGET)|$DEPLOYMENT_TARGET|g" \
    "$SRC/Info.plist" > "$APP/Contents/Info.plist"
plutil -replace CFBundleSupportedPlatforms -json '["MacOSX"]' "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
printf 'APPL????' > "$APP/Contents/PkgInfo"

# --- app icon --------------------------------------------------------------
# Regenerated from the design handoff geometry on every build; no binary blob in git.
echo "==> generating icon"
swift "$ROOT/scripts/make-icon.swift" "$BUILD/$APP_NAME.iconset" > /dev/null
iconutil -c icns "$BUILD/$APP_NAME.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

# --- sign ------------------------------------------------------------------
echo "==> signing"
codesign --force --options runtime --timestamp \
  --entitlements "$SRC/$APP_NAME.entitlements" \
  --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

# --- package ---------------------------------------------------------------
echo "==> building dmg"
STAGE="$BUILD/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" \
  -ov -format UDZO "$DMG" >/dev/null

if [[ $NOTARIZE -eq 0 ]]; then
  echo "==> skipped notarization (--no-notarize)"
  echo "    $DMG is signed but NOT notarized - Gatekeeper will warn on other Macs."
  echo "    Left in build/ so the shipped $ROOT/$APP_NAME.dmg is not clobbered."
  exit 0
fi

# --- notarize --------------------------------------------------------------
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  echo "ERROR: notarytool profile '$NOTARY_PROFILE' not found. Run:" >&2
  echo "  xcrun notarytool store-credentials $NOTARY_PROFILE \\" >&2
  echo "    --apple-id <your-apple-id> --team-id RLVYQT69D4 --password <app-specific-password>" >&2
  exit 1
fi

echo "==> notarizing (this takes a few minutes)"
codesign --sign "$SIGN_IDENTITY" --timestamp "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl -a -vvv -t open --context context:primary-signature "$DMG"

mv -f "$DMG" "$ROOT/$APP_NAME.dmg"
DMG="$ROOT/$APP_NAME.dmg"

echo
echo "==> done: $DMG"

# --- publish ---------------------------------------------------------------
if [[ -n "$PUBLISH_TAG" ]]; then
  echo "==> publishing $PUBLISH_TAG to $REPO"
  gh release create "$PUBLISH_TAG" "$DMG" -R "$REPO" \
    --title "$APP_NAME $PUBLISH_TAG" \
    --notes "$(cat <<NOTES
A lightweight macOS menu bar app that displays your upcoming calendar meetings.

### Installation
1. Download \`$APP_NAME.dmg\` below
2. Open it and drag **$APP_NAME** into your **Applications** folder
3. Launch it from Applications and grant calendar access (**Full Access** on macOS 14+)
4. Quit and relaunch once after granting access

Signed with a Developer ID certificate and notarized by Apple — no Gatekeeper warnings.
Requires macOS $DEPLOYMENT_TARGET or later. Universal (Apple Silicon + Intel).
NOTES
)"
  echo "==> https://github.com/$REPO/releases/tag/$PUBLISH_TAG"
fi
