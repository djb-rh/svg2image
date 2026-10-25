#!/bin/bash
# Builds a Release SVG2Image.app and wraps it in an installer package that puts it in /Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(sed -n 's/.*MARKETING_VERSION = \(.*\);/\1/p' SVG2Image.xcodeproj/project.pbxproj | head -1)
OUT=dist
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

xcodebuild -project SVG2Image.xcodeproj -scheme SVG2Image -configuration Release \
  -derivedDataPath build build | grep -E "error|BUILD" || true
APP="build/Build/Products/Release/SVG2Image.app"
[ -d "$APP" ] || { echo "build failed" >&2; exit 1; }

mkdir -p "$STAGE/root/Applications" "$OUT"
ditto "$APP" "$STAGE/root/Applications/SVG2Image.app"

# Not relocatable: otherwise Installer "upgrades" whatever copy it finds, such as one in a build folder.
pkgbuild --analyze --root "$STAGE/root" "$STAGE/components.plist" >/dev/null
plutil -replace 0.BundleIsRelocatable -bool NO "$STAGE/components.plist"

pkgbuild --root "$STAGE/root" --component-plist "$STAGE/components.plist" \
  --identifier com.djbarnes.SVG2Image.pkg --version "$VERSION" --install-location / \
  "$STAGE/SVG2Image-component.pkg"

productbuild --synthesize --package "$STAGE/SVG2Image-component.pkg" "$STAGE/distribution.xml"
sed -i '' "s|<installer-gui-script minSpecVersion=\"1\">|<installer-gui-script minSpecVersion=\"1\"><title>SVG2Image $VERSION</title><domains enable_localSystem=\"true\"/>|" "$STAGE/distribution.xml"
productbuild --distribution "$STAGE/distribution.xml" --package-path "$STAGE" "$OUT/SVG2Image-$VERSION.pkg"

echo "$OUT/SVG2Image-$VERSION.pkg"
