#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="WeChatExporter"
APP_DIR="$ROOT/${APP_NAME}.app"
ICON_SRC="$ROOT/assets/AppIcon.icns"
ICON_PNG="$ROOT/assets/AppIcon.png"
WX_CLI_VERSION="${WX_CLI_VERSION:-vendor}"
APP_VERSION="${APP_VERSION:-2.19.0}"
APP_BUILD="${APP_BUILD:-31}"

echo "编译原生 macOS 应用（universal: x86_64 + arm64）…"
cd "$ROOT"

# 双架构分别构建（独立 scratch 目录避免覆盖），再 lipo 合成 universal。
# 旧版 SwiftPM(Xcode 15.4/CI) 单命令多 --arch 的产物路径不可靠，分次构建对新老工具链都稳定。
UNIVERSAL_BIN="$ROOT/.build/universal/WeChatExporter"
rm -rf "$ROOT/.build/universal" "$ROOT/.build/scratch-x86_64" "$ROOT/.build/scratch-arm64"
mkdir -p "$ROOT/.build/universal"
SLICES=()
for ARCH in x86_64 arm64; do
  echo "  → 构建 $ARCH 切片…"
  swift build -c release --arch "$ARCH" --scratch-path "$ROOT/.build/scratch-$ARCH"
  CAND=""
  for C in "$ROOT/.build/scratch-$ARCH/release/WeChatExporter" \
           "$ROOT/.build/scratch-$ARCH/out/Products/Release/$APP_NAME"; do
    [[ -x "$C" ]] && CAND="$C" && break
  done
  if [[ -z "$CAND" ]]; then
    echo "警告：$ARCH 切片构建产物未找到，跳过该架构" >&2
    continue
  fi
  SLICES+=("$CAND")
done

if [[ ${#SLICES[@]} -eq 2 ]]; then
  lipo -create "${SLICES[@]}" -output "$UNIVERSAL_BIN"
  BINARY="$UNIVERSAL_BIN"
elif [[ ${#SLICES[@]} -eq 1 ]]; then
  echo "警告：仅单架构（${SLICES[0]}），另一架构交叉编译失败，继续构建" >&2
  BINARY="${SLICES[0]}"
else
  echo "错误：双架构构建均失败" >&2
  exit 1
fi

# 校验产物
ARCHS="$(lipo -archs "$BINARY" 2>/dev/null || echo '')"
if [[ -z "$ARCHS" ]]; then
  echo "错误：lipo 无法解析 $BINARY 的架构" >&2
  exit 1
fi
if [[ " $ARCHS " == *" x86_64 "* && " $ARCHS " == *" arm64 "* ]]; then
  echo "双架构校验通过：$ARCHS"
else
  echo "警告：产物仅单架构（$ARCHS）"
fi

mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BINARY" "$APP_DIR/Contents/MacOS/$APP_NAME"
chmod +x "$APP_DIR/Contents/MacOS/$APP_NAME"
rm -rf "$ROOT/.build/scratch-x86_64" "$ROOT/.build/scratch-arm64" "$ROOT/.build/universal"

echo "打包内置 wx-cli…"
bash "$ROOT/scripts/bundle_wx_cli.sh" "$APP_DIR/Contents/Resources"
chmod +x "$APP_DIR/Contents/Resources/wx-cli"

echo "打包内置 SILK 解码器(silk2wav,语音转文字用)…"
SILK2WAV="$ROOT/vendor/tools/silk/silk2wav"
if [[ -f "$SILK2WAV" ]]; then
  cp "$SILK2WAV" "$APP_DIR/Contents/Resources/silk2wav"
  chmod +x "$APP_DIR/Contents/Resources/silk2wav"
else
  echo "警告：vendor/tools/silk/silk2wav 不存在，语音 SILK 转文字功能不可用"
fi

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
