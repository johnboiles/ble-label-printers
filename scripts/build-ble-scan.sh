#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
mkdir -p .build/BLEScan.app/Contents/MacOS
cp tools/ble-scan/Info.plist .build/BLEScan.app/Contents/Info.plist

swiftc \
  -framework Foundation \
  -framework CoreBluetooth \
  -Xlinker -sectcreate \
  -Xlinker __TEXT \
  -Xlinker __info_plist \
  -Xlinker tools/ble-scan/Info.plist \
  tools/ble-scan/BLEScan.swift \
  -o .build/BLEScan.app/Contents/MacOS/ble-scan

ln -sf BLEScan.app/Contents/MacOS/ble-scan .build/ble-scan
codesign --force --sign - --entitlements tools/ble-scan/entitlements.plist .build/BLEScan.app >/dev/null

echo ".build/BLEScan.app/Contents/MacOS/ble-scan"
