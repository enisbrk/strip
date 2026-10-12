#!/bin/zsh
# Renders Resources/AppIcon.icon (the layered Icon Composer source) into the flat fallback
# Resources/AppIcon.icns used by macOS 13–15 (and the DMG volume icon), plus a 1024 px preview.
# macOS 26+ uses the layered icon itself, compiled into Assets.car by scripts/bundle.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

ICTOOL="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"
SET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$SET"
for base in 16 32 128 256 512; do
  for scale in 1 2; do
    suffix=""
    if [[ $scale == 2 ]]; then suffix="@2x"; fi
    name="icon_${base}x${base}${suffix}.png"
    "$ICTOOL" Resources/AppIcon.icon --export-image --output-file "$SET/$name" --platform macOS \
      --rendition Default --width $base --height $base --scale $scale >/dev/null
  done
done
iconutil -c icns "$SET" -o Resources/AppIcon.icns
cp "$SET/icon_512x512@2x.png" Resources/AppIcon.png
echo "Wrote Resources/AppIcon.icns and Resources/AppIcon.png"
