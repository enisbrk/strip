#!/bin/zsh
# Sets the app version and increments the build number. Usage: scripts/bump-version.sh 1.1.0
set -euo pipefail

cd "$(dirname "$0")/.."
[[ $# -eq 1 ]] || { echo "usage: $0 <version>" >&2; exit 1 }
PLIST=Resources/Info.plist
BUILD=$(( $(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$PLIST") + 1 ))
/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $1" -c "Set CFBundleVersion $BUILD" "$PLIST"
echo "Version $1 ($BUILD)"
