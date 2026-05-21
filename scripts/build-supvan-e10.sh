#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/.build/SupvanE10.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"

mkdir -p "$MACOS"
cp "$ROOT/tools/supvan-e10/Info.plist" "$CONTENTS/Info.plist"
swiftc "$ROOT/tools/supvan-e10/SupvanE10.swift" \
  -framework Foundation \
  -framework CoreBluetooth \
  -o "$MACOS/supvan-e10"

codesign --force --sign - \
  --entitlements "$ROOT/tools/supvan-e10/entitlements.plist" \
  "$APP"

echo "$MACOS/supvan-e10"
