#!/bin/bash
# Build three things from one core — no Xcode project, just swiftc.
#
#   Core/   pure logic, no AppKit, no CoreBluetooth
#   App/    the menu bar app + everything that touches macOS
#   Tools/  the radio-dependent commands
#   Tests/  assertions against Core only, so they need no radio and no permission
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Waylock.app"
BIN="$APP/Contents/MacOS/Waylock"
FLAGS=(-O -target arm64-apple-macos13.0)

echo "==> core tests"
swiftc "${FLAGS[@]}" Core/*.swift Tests/main.swift -o build/waylock-tests.tmp
mv build/waylock-tests.tmp build/waylock-tests

echo "==> tools"
swiftc "${FLAGS[@]}" -framework CoreBluetooth \
    Core/*.swift \
    App/Log.swift App/Radio.swift App/SettingsStore.swift \
    Tools/main.swift \
    -o build/waylock-tools.tmp
mv build/waylock-tools.tmp build/waylock-tools

echo "==> app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc "${FLAGS[@]}" \
    -framework AppKit \
    -framework CoreBluetooth \
    -framework IOKit \
    -framework ServiceManagement \
    Core/*.swift App/*.swift \
    -o "$BIN"

echo "==> bundling"
cp App/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signature: the private lock API rules out notarisation, and TCC keys
# Bluetooth permission to the code signature, so every rebuild asks again.
# See README — a stable signing identity is the durable fix.
echo "==> signing (ad-hoc)"
codesign --force --sign - --identifier io.github.hheydaroff.waylock "$APP"

echo "==> verifying"
codesign --verify --verbose=2 "$APP" 2>&1 | sed 's/^/    /'
/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist" | sed 's/^/    bundle id: /'
ls -lh "$BIN" build/waylock-tests build/waylock-tools | awk '{print "    "$9": "$5}'

cat <<EOF

Built: $(pwd)/$APP

  ./build/waylock-tests           # logic: windows, identity, decision, menu copy
  ./build/waylock-tools --calibrate 10
  open "$(pwd)/$APP"              # launch
  tail -f ~/Library/Logs/Waylock.log

The app needs Bluetooth permission, granted per code signature: a rebuild asks
again. CLI runs (tests, tools) inherit the Terminal's grant and never ask.
EOF