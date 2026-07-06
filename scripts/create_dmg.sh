#!/bin/bash
# 将 WeChatExporter.app 打包为标准 macOS DMG 安装镜像（拖拽到「应用程序」即可安装）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="WeChatExporter"
APP_DIR="$ROOT/${APP_NAME}.app"
DMG_NAME="${1:-WeChatExporter-macOS-arm64.dmg}"
VOL_NAME="微信聊天记录导出"

if [[ ! -d "$APP_DIR" ]]; then
  echo "错误：未找到 ${APP_NAME}.app，请先运行 ./build_app.sh"
  exit 1
fi

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

echo "准备 DMG 内容…"
cp -R "$APP_DIR" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

OUT="$ROOT/$DMG_NAME"
rm -f "$OUT"

echo "创建 DMG：$OUT"
hdiutil create \
  -volname "$VOL_NAME" \
  -srcfolder "$STAGING" \
  -ov \
  -format UDZO \
  "$OUT"

echo "完成: $OUT"
echo "安装：打开 DMG，将 WeChatExporter 拖到「应用程序」文件夹"
