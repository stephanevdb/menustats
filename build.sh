#!/bin/zsh
# Builds build/MenuStats.app. Pass --install to copy it to /Applications.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/MenuStats"

APP=build/MenuStats.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MenuStats"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# A stable identity keeps macOS permissions (Location, Full Disk Access, notifications)
# across rebuilds; ad-hoc signatures change every build, so macOS forgets them.
IDENTITY="MenuStats Local Signing"
if security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
  codesign --force --sign "$IDENTITY" "$APP"
else
  echo "warning: \"$IDENTITY\" certificate not found, signing ad-hoc (permissions reset on each build)"
  codesign --force --sign - "$APP"
fi

if [[ "${1:-}" == "--install" ]]; then
  pkill -x MenuStats || true
  rm -rf /Applications/MenuStats.app
  cp -R "$APP" /Applications/
  echo "Installed to /Applications/MenuStats.app"
else
  echo "Built $APP"
fi
