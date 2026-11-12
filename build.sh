#!/bin/zsh
# Builds ThreeThings.app next to this script. Run with "./build.sh run" to also launch it.
set -e
cd "$(dirname "$0")"
swift build -c release
rm -rf ThreeThings.app
mkdir -p ThreeThings.app/Contents/MacOS
cp .build/release/ThreeThings ThreeThings.app/Contents/MacOS/ThreeThings
cp Info.plist ThreeThings.app/Contents/Info.plist
mkdir -p ThreeThings.app/Contents/Resources
cp icon/AppIcon.icns ThreeThings.app/Contents/Resources/AppIcon.icns
# Hardened runtime: stops other programs loading code into the app to borrow its browser permission.
codesign --force --options runtime --entitlements ThreeThings.entitlements --sign - ThreeThings.app
echo "Built $(pwd)/ThreeThings.app"
if [[ "$1" == "run" ]]; then
  pkill -x ThreeThings 2>/dev/null || true
  open ThreeThings.app
fi
