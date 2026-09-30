#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/.build/NiimbotB21S.app"
SOURCE="$ROOT/tools/niimbot-b21s"
MACOS="$APP/Contents/MacOS"

mkdir -p "$MACOS" "$ROOT/.build/niimbot-swift-module-cache"
cp "$SOURCE/Info.plist" "$APP/Contents/Info.plist"
swiftc "$SOURCE/NiimbotB21S.swift" \
  -target "$(uname -m)-apple-macosx14.0" \
  -module-cache-path "$ROOT/.build/niimbot-swift-module-cache" \
  -framework Foundation -framework CoreBluetooth \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$SOURCE/Info.plist" \
  -o "$MACOS/niimbot-b21s"
codesign --force --sign - --entitlements "$SOURCE/entitlements.plist" "$APP"
ln -sf NiimbotB21S.app/Contents/MacOS/niimbot-b21s "$ROOT/.build/niimbot-b21s"
echo "$MACOS/niimbot-b21s"
