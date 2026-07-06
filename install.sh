#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/WeChatExporter.app"

"$ROOT/build_app.sh"

# 删除旧的 Python 版应用
for old in \
  "$HOME/WeChatExporter.app" \
  "$HOME/WeChatExporter/WeChatExporter.app" \
  "$HOME/Applications/WeChatExporter.app"; do
  if [[ -e "$old" ]]; then
    rm -rf "$old"
    echo "已删除旧版：$old"
  fi
done

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
echo ""
echo "这是纯 Swift/SwiftUI 原生应用，不再依赖 Python。"
