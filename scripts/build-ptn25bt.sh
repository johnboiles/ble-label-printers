#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
mkdir -p .build/PTN25BT.app/Contents/MacOS
cp tools/ptn25bt/Info.plist .build/PTN25BT.app/Contents/Info.plist

swiftc \
  -framework Foundation \
  -framework CoreBluetooth \
  -Xlinker -sectcreate \
  -Xlinker __TEXT \
  -Xlinker __info_plist \
  -Xlinker tools/ptn25bt/Info.plist \
  tools/ptn25bt/PTN25BT.swift \
  -o .build/PTN25BT.app/Contents/MacOS/ptn25bt

ln -sf PTN25BT.app/Contents/MacOS/ptn25bt .build/ptn25bt
codesign --force --sign - --entitlements tools/ptn25bt/entitlements.plist .build/PTN25BT.app >/dev/null

echo ".build/PTN25BT.app/Contents/MacOS/ptn25bt"

