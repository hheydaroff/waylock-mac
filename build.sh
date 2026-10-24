#!/bin/bash
# Build the menu bar app bundle. Everything else is plain SwiftPM:
#
#   swift build                      libraries, tools, probes
#   swift test                       every decision, no radio, no locking
#   swift run waylock-tools ...      the radio-dependent commands
#
# SwiftPM cannot make a signed .app, so this script does only that. It runs
# `swift build` first so a broken tool or test target fails here, before an app is
# signed, rather than at the next `swift run`.
#
#   Core/      pure logic: Foundation only
#   Adapters/  CoreBluetooth and UserDefaults, shared with the tools
#   App/       the menu bar app: AppKit, IOKit, ServiceManagement
#
# The app is compiled as one module from the sources, not linked against the
# SwiftPM libraries, so Core and Adapters need no `public` declarations.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Waylock.app"
BIN="$APP/Contents/MacOS/Waylock"
# Swift 6 language mode: the whole tree compiles clean, so a new warning or a data
# race is a build failure rather than a note in a log nobody reads.
FLAGS=(-O -target arm64-apple-macos13.0 -swift-version 6)

echo "==> swift build"
swift build

echo "==> app"
# Targeted deletes, not `rm -rf`: a bundle is three known paths, and a recursive
# delete in a build script is one bad variable away from removing something real.
rm -f "$BIN" "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc "${FLAGS[@]}" \
    -framework AppKit \
    -framework CoreBluetooth \
    -framework IOKit \
    -framework ServiceManagement \
    Core/*.swift Adapters/*.swift App/main.swift App/Locker.swift \
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
ls -lh "$BIN" | awk '{print "    "$9": "$5}'

cat <<EOT

Built: $(pwd)/$APP

  swift test                          # logic: windows, identity, decision, menu copy
  swift run waylock-tools --selftest 60
  open "$(pwd)/$APP"                  # launch
  tail -f ~/Library/Logs/Waylock.log

The app needs Bluetooth permission, granted per code signature: a rebuild asks
again. CLI runs (tests, tools) inherit the Terminal's grant and never ask.
EOT
