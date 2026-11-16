#!/bin/bash
# Builds AudioControl.app into ./build. Pass --install to copy it to /Applications.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=build/AudioControl.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O Tools/IconRenderer/main.swift -o build/icon-renderer
build/icon-renderer appicon build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
cp .build/release/AudioControl "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x AudioControl || true
    rm -rf /Applications/AudioControl.app
    cp -R "$APP" /Applications/
    echo "Installed /Applications/AudioControl.app"
fi
