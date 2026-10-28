#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="基金盈亏"
APP="$APP_NAME.app"
MODCACHE="$PWD/.build/modcache"
mkdir -p "$MODCACHE" "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "→ 编译 Swift ..."
swiftc -O \
  -module-cache-path "$MODCACHE" \
  -target arm64-apple-macos13.0 \
  -framework Cocoa \
  -o "$APP/Contents/MacOS/FundBar" \
  Sources/main.swift

cp Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "→ 临时签名 ..."
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 || true

echo "✓ 已生成：$PWD/$APP"
