#!/bin/zsh
# Builds a release Strip.app and packages it as build/Strip-<version>.dmg with a
# drag-to-Applications window.
#
# Notarization (needs a Developer ID Application certificate): store credentials once with
#   xcrun notarytool store-credentials strip-notary --apple-id <id> --team-id <team> --password <app-specific>
# then run: NOTARY_PROFILE=strip-notary scripts/make-dmg.sh
# Upload build/Strip.dmg to a GitHub release so the website's download link finds it.
set -euo pipefail

cd "$(dirname "$0")/.."
scripts/bundle.sh release

APP="build/Strip.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="build/Strip-$VERSION.dmg"
VOLUME="Strip $VERSION"
STAGING="build/dmg-staging"
RW_DMG="build/Strip-rw.dmg"

rm -rf "$STAGING" "$RW_DMG" "$DMG"
mkdir -p "$STAGING/.background"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
swift scripts/make-dmg-background.swift "$STAGING/.background/background.png"

# Writable image first so the Finder window can be laid out, then compress it.
hdiutil create -quiet -volname "$VOLUME" -srcfolder "$STAGING" -fs HFS+ -format UDRW -ov "$RW_DMG"
# Detach any stale mount of a previous run.
[[ -d "/Volumes/$VOLUME" ]] && hdiutil detach -quiet "/Volumes/$VOLUME" || true
hdiutil attach -quiet -readwrite -noverify -noautoopen "$RW_DMG"

# Lay out the window. Needs Finder automation permission; the DMG still works without it.
osascript <<EOF || echo "warning: could not style the DMG window (Finder automation not allowed)"
tell application "Finder"
  tell disk "$VOLUME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 520}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 112
    set text size of viewOptions to 13
    set background picture of viewOptions to file ".background:background.png"
    set position of item "Strip.app" of container window to {170, 190}
    set position of item "Applications" of container window to {490, 190}
    update without registering applications
    delay 1
    close
  end tell
end tell
EOF
cp Resources/AppIcon.icns "/Volumes/$VOLUME/.VolumeIcon.icns"
SetFile -a C "/Volumes/$VOLUME" 2>/dev/null || true
sync
hdiutil detach -quiet "/Volumes/$VOLUME"

hdiutil convert -quiet "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG"
rm -rf "$RW_DMG" "$STAGING"

IDENTITY="$(security find-identity -v -p codesigning | awk '/Developer ID Application/ {print $2; exit}')"
if [[ -n "$IDENTITY" ]]; then
  codesign --force --timestamp --sign "$IDENTITY" "$DMG"
else
  IDENTITY="$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')"
  [[ -n "$IDENTITY" ]] && codesign --force --sign "$IDENTITY" "$DMG"
fi

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  spctl -a -t open --context context:primary-signature -vv "$DMG"
else
  echo "warning: not notarized (set NOTARY_PROFILE); Gatekeeper will block it on other Macs." >&2
fi

hdiutil verify -quiet "$DMG"
# Fixed name for the "latest release" download link on the website.
cp "$DMG" build/Strip.dmg
echo "Created $DMG ($(du -h "$DMG" | cut -f1))"
