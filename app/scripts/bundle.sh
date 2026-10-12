#!/bin/zsh
# Builds Strip.app into ./build. Usage: scripts/bundle.sh [debug|release]
# Release builds are universal (Apple silicon + Intel).
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
APP="build/Strip.app"

ARCH_FLAGS=()
[[ "$CONFIG" == "release" ]] && ARCH_FLAGS=(--arch arm64 --arch x86_64)

swift build -c "$CONFIG" "${ARCH_FLAGS[@]}"
BIN_DIR="$(swift build -c "$CONFIG" "${ARCH_FLAGS[@]}" --show-bin-path)"
BIN="$BIN_DIR/Strip"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Strip"
# Sparkle (automatic updates); ditto keeps the framework's symlinks intact.
mkdir -p "$APP/Contents/Frameworks"
ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Layered Liquid Glass icon for macOS 26+ (Assets.car); macOS 13–15 use AppIcon.icns above.
ICON_OUT="$(mktemp -d)"
xcrun actool Resources/AppIcon.icon --compile "$ICON_OUT" --platform macosx --minimum-deployment-target 13.0 \
  --app-icon AppIcon --output-partial-info-plist "$ICON_OUT/partial.plist" --target-device mac >/dev/null
cp "$ICON_OUT/Assets.car" "$APP/Contents/Resources/Assets.car"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Accessibility permission is tied to the code signature. An ad-hoc signature changes on
# every build, so macOS forgets the permission; a real certificate keeps it across rebuilds.
# A "Developer ID Application" certificate is preferred: it is what Gatekeeper and notarization need.
IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null)"
IDENTITY="$(echo "$IDENTITIES" | awk '/Developer ID Application/ {print $2; exit}')"

# Signs Sparkle's helpers from the inside out, as Sparkle's documentation describes.
sign_sparkle() {
  local sparkle="$APP/Contents/Frameworks/Sparkle.framework" flags=("$@")
  codesign "${flags[@]}" "$sparkle/Versions/B/XPCServices/Installer.xpc"
  codesign "${flags[@]}" --preserve-metadata=entitlements "$sparkle/Versions/B/XPCServices/Downloader.xpc"
  codesign "${flags[@]}" "$sparkle/Versions/B/Autoupdate"
  codesign "${flags[@]}" "$sparkle/Versions/B/Updater.app"
  codesign "${flags[@]}" "$sparkle"
}

if [[ -n "$IDENTITY" ]]; then
  echo "Signing with Developer ID ($IDENTITY), hardened runtime"
  sign_sparkle --force --options runtime --timestamp --sign "$IDENTITY"
  codesign --force --options runtime --timestamp --entitlements Resources/Strip.entitlements \
    --sign "$IDENTITY" "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
else
  [[ "$CONFIG" == "release" ]] && echo "warning: no Developer ID Application certificate; this build can't be notarized or shared." >&2
  IDENTITY="$(echo "$IDENTITIES" | awk '/Apple Development|Strip Local/ {print $2; exit}')"
  if [[ -n "$IDENTITY" ]]; then
    echo "Signing with development certificate $IDENTITY"
    sign_sparkle --force --sign "$IDENTITY"
    codesign --force --sign "$IDENTITY" "$APP"
  else
    echo "No signing certificate found; using ad-hoc signature."
    echo "You will need to re-grant Accessibility access after each rebuild:"
    echo "  tccutil reset Accessibility com.enisburakdemirci.strip"
    sign_sparkle --force --sign -
    codesign --force --sign - "$APP"
  fi
fi

echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/Strip"))"
