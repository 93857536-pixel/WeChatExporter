#!/bin/bash
# 将 WeChatExporter.app 打包为带自定义背景的 macOS DMG 安装镜像
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="WeChatExporter"
APP_DIR="$ROOT/${APP_NAME}.app"
DMG_NAME="${1:-WeChatExporter-macOS-arm64.dmg}"
VOL_NAME="微信聊天记录导出"
GENERATOR="$ROOT/scripts/generate_dmg_background.py"
BG_1X="$ROOT/assets/dmg-background.png"
BG_2X="$ROOT/assets/dmg-background@2x.png"

# Finder 窗口逻辑尺寸（points）——必须与背景图 1x 像素尺寸一致
WINDOW_W=660
WINDOW_H=400

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "错误：DMG 打包需在 macOS 上运行（依赖 hdiutil / Finder）"
  exit 1
fi

if [[ ! -d "$APP_DIR" ]]; then
  echo "错误：未找到 ${APP_NAME}.app，请先运行 ./build_app.sh"
  exit 1
fi

regenerate_background() {
  echo "生成 DMG 背景图（1x + 2x）…"
  if ! python3 "$GENERATOR"; then
    echo "错误：无法生成背景图（需要 Python 3 + Pillow）"
    exit 1
  fi
}

if [[ ! -f "$BG_1X" ]] || [[ ! -f "$BG_2X" ]] || [[ "$GENERATOR" -nt "$BG_1X" ]]; then
  regenerate_background
fi

prepare_background_assets() {
  local dir="$1"
  mkdir -p "$dir"
  cp "$BG_1X" "$dir/background.png"
  cp "$BG_2X" "$dir/background@2x.png"

  # 确保 DPI 正确（Finder 靠 DPI 计算背景逻辑尺寸，不会自动缩放）
  sips -s dpiWidth 72 -s dpiHeight 72 "$dir/background.png" >/dev/null
  sips -s dpiWidth 144 -s dpiHeight 144 "$dir/background@2x.png" >/dev/null

  if command -v tiffutil >/dev/null 2>&1; then
    tiffutil -cathidpicheck "$dir/background.png" "$dir/background@2x.png" -out "$dir/background.tiff" >/dev/null
    echo "background.tiff"
  else
    echo "background.png"
  fi
}

STAGING="$(mktemp -d)"
DMG_RW="$(mktemp -t WeChatExporter.XXXXXX).dmg"
trap 'rm -rf "$STAGING" "$DMG_RW"' EXIT

echo "准备 DMG 内容…"
BG_DIR="$STAGING/.background"
BG_FILE="$(prepare_background_assets "$BG_DIR")"
cp -R "$APP_DIR" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

if [[ -f "$ROOT/assets/AppIcon.icns" ]]; then
  cp "$ROOT/assets/AppIcon.icns" "$STAGING/.VolumeIcon.icns"
fi

SIZE_MB=$(( $(du -sm "$STAGING" | awk '{print $1}') + 64 ))
echo "创建临时 DMG（${SIZE_MB} MB，窗口 ${WINDOW_W}×${WINDOW_H}pt）…"
hdiutil create \
  -volname "$VOL_NAME" \
  -srcfolder "$STAGING" \
  -ov \
  -format UDRW \
  -size "${SIZE_MB}m" \
  "$DMG_RW" >/dev/null

echo "挂载并配置 Finder 窗口…"
ATTACH_OUT="$(hdiutil attach -readwrite -noverify -noautoopen "$DMG_RW")"
DEVICE="$(echo "$ATTACH_OUT" | awk '/^\/dev\// {print $1; exit}')"
MOUNT_POINT="/Volumes/$VOL_NAME"

if [[ ! -d "$MOUNT_POINT" ]]; then
  echo "错误：未能挂载 DMG 到 $MOUNT_POINT"
  exit 1
fi

# 挂载后再次写入背景（确保 DPI / TIFF 在卷内正确）
prepare_background_assets "$MOUNT_POINT/.background" >/dev/null
BG_BASENAME="$(basename "$BG_FILE")"

chflags hidden "$MOUNT_POINT/.background" 2>/dev/null || true
if [[ -f "$MOUNT_POINT/.VolumeIcon.icns" ]]; then
  chflags hidden "$MOUNT_POINT/.VolumeIcon.icns" 2>/dev/null || true
  if command -v SetFile >/dev/null 2>&1; then
    SetFile -a C "$MOUNT_POINT"
  fi
fi

chmod -Rf go-w "$MOUNT_POINT" 2>/dev/null || true

WIN_LEFT=200
WIN_TOP=120
WIN_RIGHT=$((WIN_LEFT + WINDOW_W))
WIN_BOTTOM=$((WIN_TOP + WINDOW_H))

/usr/bin/osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$VOL_NAME"
    open
    set theWindow to container window
    set current view of theWindow to icon view
    set toolbar visible of theWindow to false
    set statusbar visible of theWindow to false
    set sidebar width of theWindow to 0
    set the bounds of theWindow to {$WIN_LEFT, $WIN_TOP, $WIN_RIGHT, $WIN_BOTTOM}

    set viewOptions to icon view options of theWindow
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 128
    set text size of viewOptions to 12
    set shows item info of viewOptions to false
    set shows icon preview of viewOptions to true
    set background picture of viewOptions to file ".background:$BG_BASENAME"

    set position of item "$APP_NAME.app" of theWindow to {180, 170}
    set position of item "Applications" of theWindow to {480, 170}

    close
    open
    update without registering applications
    delay 2
  end tell
end tell
APPLESCRIPT

if command -v bless >/dev/null 2>&1; then
  bless --folder "$MOUNT_POINT" --openfolder "$MOUNT_POINT" 2>/dev/null || true
fi

sync
sleep 1
hdiutil detach "$DEVICE" >/dev/null

OUT="$ROOT/$DMG_NAME"
rm -f "$OUT"
echo "压缩 DMG：$OUT"
hdiutil convert "$DMG_RW" -format UDZO -imagekey zlib-level=9 -o "$OUT" >/dev/null

echo "完成: $OUT"
echo "安装：打开 DMG，将 WeChatExporter 拖到「应用程序」文件夹"
