#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="WeChatExporter"
APP_DIR="$ROOT/${APP_NAME}.app"
BINARY="$ROOT/.build/release/WeChatExporter"
ICON_SRC="$ROOT/assets/AppIcon.icns"
ICON_PNG="$ROOT/assets/AppIcon.png"
WX_CLI_VERSION="${WX_CLI_VERSION:-v0.7.2}"
APP_VERSION="${APP_VERSION:-2.3.7}"
APP_BUILD="${APP_BUILD:-11}"

echo "编译原生 macOS 应用…"
cd "$ROOT"
swift build -c release

mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BINARY" "$APP_DIR/Contents/MacOS/$APP_NAME"
chmod +x "$APP_DIR/Contents/MacOS/$APP_NAME"

echo "打包内置 wx-cli ${WX_CLI_VERSION}…"
WX_CLI_VERSION="$WX_CLI_VERSION" bash "$ROOT/scripts/bundle_wx_cli.sh" "$APP_DIR/Contents/Resources"
chmod +x "$APP_DIR/Contents/Resources/wx-cli"

bash "$ROOT/scripts/prepare_icon.sh"
if [[ -f "$ICON_SRC" ]]; then
  cp "$ICON_SRC" "$APP_DIR/Contents/Resources/AppIcon.icns"
elif [[ -f "$ICON_PNG" ]]; then
  echo "警告：未生成 AppIcon.icns，请在 macOS 上运行 scripts/prepare_icon.sh"
  echo "      当前环境无法生成正确尺寸的 macOS 图标。"
fi

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>com.local.wechat-exporter</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>微信聊天记录导出</string>
    <key>CFBundleDisplayName</key>
    <string>微信聊天记录导出</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${APP_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${APP_BUILD}</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSRequiresNativeExecution</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
</dict>
</plist>
PLIST

xattr -cr "$APP_DIR" 2>/dev/null || true
codesign --force --deep --sign - "$APP_DIR" 2>/dev/null || true

echo "完成: $APP_DIR"
echo ""
echo "可选：生成 DMG 安装包"
echo "  bash scripts/create_dmg.sh"
