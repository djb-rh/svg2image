#!/bin/bash
# Builds a Release SVG2Image.app and packages it as dist/SVG2Image-<version>.dmg and .pkg.
#
# With no settings everything is ad-hoc signed. For a release Gatekeeper accepts, set:
#   SIGN_IDENTITY       "Developer ID Application: Name (TEAMID)"  signs the app and the DMG
#   INSTALLER_IDENTITY  "Developer ID Installer: Name (TEAMID)"    signs the pkg (pkg is left unsigned without it)
#   NOTARY_PROFILE      a notarytool keychain profile, made once with
#                       xcrun notarytool store-credentials NAME --apple-id ... --team-id ...
set -euo pipefail
cd "$(dirname "$0")/.."

SIGN_IDENTITY=${SIGN_IDENTITY:-}
INSTALLER_IDENTITY=${INSTALLER_IDENTITY:-}
NOTARY_PROFILE=${NOTARY_PROFILE:-}
VERSION=$(sed -n 's/.*MARKETING_VERSION = \(.*\);/\1/p' SVG2Image.xcodeproj/project.pbxproj | head -1)
OUT=dist
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$OUT"

notarize() {
  [ -n "$NOTARY_PROFILE" ] || return 0
  echo "==> notarizing $(basename "$1")"
  xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait | tee "$STAGE/notary.log"
  grep -q "status: Accepted" "$STAGE/notary.log" || { echo "notarization failed" >&2; exit 1; }
}

echo "==> building $VERSION"
xcodebuild -project SVG2Image.xcodeproj -scheme SVG2Image -configuration Release \
  -derivedDataPath build build | grep -E "error|BUILD" || true
mkdir -p "$STAGE/root/Applications"
APP="$STAGE/root/Applications/SVG2Image.app"
ditto --noextattr --norsrc build/Build/Products/Release/SVG2Image.app "$APP"

if [ -n "$SIGN_IDENTITY" ]; then
  echo "==> signing app with $SIGN_IDENTITY"
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
  codesign --verify --strict --verbose=2 "$APP"
  ditto -c -k --keepParent "$APP" "$STAGE/SVG2Image.zip"
  notarize "$STAGE/SVG2Image.zip"
  [ -z "$NOTARY_PROFILE" ] || xcrun stapler staple "$APP"
fi

echo "==> DMG"
mkdir -p "$STAGE/dmg"
ditto "$APP" "$STAGE/dmg/SVG2Image.app"
ln -s /Applications "$STAGE/dmg/Applications"
DMG="$OUT/SVG2Image-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "SVG2Image $VERSION" -srcfolder "$STAGE/dmg" -ov -format UDZO "$DMG" >/dev/null
if [ -n "$SIGN_IDENTITY" ]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
  notarize "$DMG"
  [ -z "$NOTARY_PROFILE" ] || xcrun stapler staple "$DMG"
fi

echo "==> pkg"
# Not relocatable: otherwise Installer "upgrades" whatever copy it finds, such as one in a build folder.
pkgbuild --analyze --root "$STAGE/root" "$STAGE/components.plist" >/dev/null
plutil -replace 0.BundleIsRelocatable -bool NO "$STAGE/components.plist"
pkgbuild --root "$STAGE/root" --component-plist "$STAGE/components.plist" \
  --identifier com.djbarnes.SVG2Image.pkg --version "$VERSION" --install-location / \
  "$STAGE/SVG2Image-component.pkg" >/dev/null
productbuild --synthesize --package "$STAGE/SVG2Image-component.pkg" "$STAGE/distribution.xml" >/dev/null
sed -i '' "s|<installer-gui-script minSpecVersion=\"1\">|<installer-gui-script minSpecVersion=\"1\"><title>SVG2Image $VERSION</title><domains enable_localSystem=\"true\"/>|" "$STAGE/distribution.xml"
PKG="$OUT/SVG2Image-$VERSION.pkg"
if [ -n "$INSTALLER_IDENTITY" ]; then
  productbuild --distribution "$STAGE/distribution.xml" --package-path "$STAGE" \
    --sign "$INSTALLER_IDENTITY" --timestamp "$PKG" >/dev/null
  notarize "$PKG"
  [ -z "$NOTARY_PROFILE" ] || xcrun stapler staple "$PKG"
else
  productbuild --distribution "$STAGE/distribution.xml" --package-path "$STAGE" "$PKG" >/dev/null
  echo "    (pkg unsigned: set INSTALLER_IDENTITY to sign and notarize it)"
fi

echo "==> done"
ls -l "$OUT"/SVG2Image-"$VERSION".*
