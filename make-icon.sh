#!/bin/zsh
# Renders the icon artwork (Sources/MenuStats/AppIconArt.swift) and builds Resources/AppIcon.icns.
set -euo pipefail
cd "$(dirname "$0")"

swift build
WORK="$(mktemp -d)"
.build/debug/MenuStats --snapshot "$WORK" --icon

SET="$WORK/AppIcon.iconset"
mkdir -p "$SET"
for size in 16 32 128 256 512; do
  sips -z $size $size "$WORK/AppIcon-1024.png" --out "$SET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) "$WORK/AppIcon-1024.png" --out "$SET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o Resources/AppIcon.icns
rm -rf "$WORK"
echo "Wrote Resources/AppIcon.icns"
