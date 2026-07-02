#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/WeChatExporter.app"

"$ROOT/build_app.sh"

for target in "$HOME/Desktop/WeChatExporter.app" "/Applications/WeChatExporter.app"; do
  rm -rf "$target"
  cp -R "$APP" "$target"
  xattr -cr "$target" 2>/dev/null || true
  codesign --force --deep --sign - "$target" 2>/dev/null || true
done

echo ""
echo "原生 Swift 应用已安装到："
echo "  ~/Desktop/WeChatExporter.app"
echo "  /Applications/WeChatExporter.app"
