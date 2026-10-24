#!/bin/bash
# Build Waylock.app — no Xcode project, just swiftc + a hand-made bundle.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Waylock.app"
BIN="$APP/Contents/MacOS/Waylock"

echo "==> compiling"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O \
    -target arm64-apple-macos13.0 \
    -framework AppKit \
    -framework CoreBluetooth \
    -framework IOKit \
    -framework ApplicationServices \
    -framework ServiceManagement \
    Waylock/Waylock.swift \
    -o "$BIN"

echo "==> bundling"
cp Waylock/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signature: the private lock API rules out notarisation, and TCC keys
# Bluetooth permission to the bundle identity, so it must be signed.
echo "==> signing (ad-hoc)"
codesign --force --sign - --identifier io.github.hheydaroff.waylock "$APP"

echo "==> verifying"
codesign --verify --verbose=2 "$APP" 2>&1 | sed 's/^/    /'
/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist" | sed 's/^/    bundle id: /'
ls -lh "$BIN" | awk '{print "    binary: "$5}'

cat <<EOF

Built: $(pwd)/$APP

  open "$(pwd)/$APP"          # launch
  tail -f ~/Library/Logs/Waylock.log

First launch will ask for Bluetooth permission — accept it, or the app will
sit in "Bluetooth unavailable".
EOF