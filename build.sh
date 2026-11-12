#!/bin/zsh
# Builds OneThing.app next to this script. Run with "./build.sh run" to also launch it.
set -e
cd "$(dirname "$0")"
swift build -c release
rm -rf OneThing.app
mkdir -p OneThing.app/Contents/MacOS
cp .build/release/OneThing OneThing.app/Contents/MacOS/OneThing
cp Info.plist OneThing.app/Contents/Info.plist
mkdir -p OneThing.app/Contents/Resources
cp icon/AppIcon.icns OneThing.app/Contents/Resources/AppIcon.icns
# Hardened runtime: stops other programs loading code into the app to borrow its browser permission.
codesign --force --options runtime --entitlements OneThing.entitlements --sign - OneThing.app
echo "Built $(pwd)/OneThing.app"
if [[ "$1" == "run" ]]; then
  pkill -x OneThing 2>/dev/null || true
  open OneThing.app
fi
