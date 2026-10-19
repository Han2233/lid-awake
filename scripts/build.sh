#!/bin/bash
# 构建 Lid Awake.app（不安装）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Lid Awake.app"
CACHE="$ROOT/build/modulecache"

command -v xcrun >/dev/null 2>&1 || {
  echo "error: 找不到 xcrun，请先安装 Xcode Command Line Tools：xcode-select --install" >&2
  exit 1
}

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$CACHE"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"

xcrun swiftc -O -module-cache-path "$CACHE" \
  -o "$APP/Contents/MacOS/LidAwake" "$ROOT/LidAwake.swift" -framework Cocoa

codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
echo "built: $APP"
