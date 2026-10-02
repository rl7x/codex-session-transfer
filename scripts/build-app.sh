#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build -c release --product CodexSessionTransfer

APP="$ROOT/CodexSessionTransfer.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$ROOT/.build/release/CodexSessionTransfer" "$APP/Contents/MacOS/CodexSessionTransfer"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
chmod +x "$APP/Contents/MacOS/CodexSessionTransfer"
codesign --force --sign - "$APP"
echo "Built $APP"
