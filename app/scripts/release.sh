#!/bin/zsh
# Publishes a new version: notarized DMG, Sparkle appcast entry, website version, GitHub release.
#
#   scripts/bump-version.sh 1.1.0
#   NOTARY_PROFILE=strip-notary scripts/release.sh "Release notes, one line or HTML"
#
# Then commit and push; GitHub Pages serves ../appcast.xml, which every installed copy checks daily.
# Needs: Developer ID certificate, the notary profile (see make-dmg.sh), the Sparkle EdDSA key in the
# login keychain (created once with .build/artifacts/sparkle/Sparkle/bin/generate_keys) and gh.
set -euo pipefail

cd "$(dirname "$0")/.."
REPO="enisbrk/strip"
NOTES="${1:-Bug fixes and improvements.}"
[[ -n "${NOTARY_PROFILE:-}" ]] || { echo "Set NOTARY_PROFILE; updates must be notarized." >&2; exit 1 }

scripts/make-dmg.sh

PLIST=build/Strip.app/Contents/Info.plist
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$PLIST")"
MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print LSMinimumSystemVersion' "$PLIST")"
DMG="build/Strip-$VERSION.dmg"
SIGNATURE="$(.build/artifacts/sparkle/Sparkle/bin/sign_update "$DMG")"
URL="https://github.com/$REPO/releases/download/v$VERSION/Strip-$VERSION.dmg"

python3 - "$VERSION" "$BUILD" "$MIN_OS" "$URL" "$SIGNATURE" "$NOTES" <<'PY'
import sys, pathlib, email.utils, html
version, build, min_os, url, signature, notes = sys.argv[1:]
path = pathlib.Path("../appcast.xml")
item = f"""    <item>
      <title>Version {version}</title>
      <pubDate>{email.utils.formatdate(localtime=True)}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{min_os}</sparkle:minimumSystemVersion>
      <description><![CDATA[<p>{notes}</p>]]></description>
      <enclosure url="{html.escape(url)}" type="application/octet-stream" {signature}/>
    </item>
"""
text = path.read_text()
if f"<sparkle:version>{build}</sparkle:version>" in text:
    sys.exit(f"appcast.xml already lists build {build}; run scripts/bump-version.sh first")
marker = "<language>en</language>\n"
path.write_text(text.replace(marker, marker + item, 1))
PY

# The website shows the current version next to the download button.
sed -i '' "s/^const VERSION = \".*\";/const VERSION = \"$VERSION\";/" ../assets/js/main.js

if command -v gh >/dev/null; then
  gh release create "v$VERSION" "$DMG" build/Strip.dmg --repo "$REPO" --title "Strip $VERSION" --notes "$NOTES"
else
  echo "gh not found: create release v$VERSION on GitHub and upload $DMG and build/Strip.dmg."
fi
echo "Released $VERSION ($BUILD). Commit and push appcast.xml and assets/js/main.js to publish the update."
