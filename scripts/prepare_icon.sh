#!/bin/bash
# 从 assets/AppIcon.png 生成 macOS AppIcon.icns（需在 macOS 上运行）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PNG="$ROOT/assets/AppIcon.png"
ICONSET="$ROOT/assets/AppIcon.iconset"
ICNS="$ROOT/assets/AppIcon.icns"

if [[ ! -f "$PNG" ]]; then
  echo "错误：未找到 $PNG"
  exit 1
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "跳过 icns 生成：当前非 macOS 环境（Release 构建需在 macOS 上生成 icns）"
  exit 0
fi

# 确保源图为 1024×1024，macOS 图标需要标准尺寸
WIDTH=$(sips -g pixelWidth "$PNG" 2>/dev/null | awk '/pixelWidth/ {print $2; exit}')
HEIGHT=$(sips -g pixelHeight "$PNG" 2>/dev/null | awk '/pixelHeight/ {print $2; exit}')
if [[ -z "$WIDTH" || -z "$HEIGHT" ]]; then
  echo "错误：无法读取 $PNG 的尺寸"
  exit 1
fi
if [[ "$WIDTH" != "$HEIGHT" ]]; then
  side=$(( WIDTH < HEIGHT ? WIDTH : HEIGHT ))
  echo "裁剪源图为 ${side}×${side}（当前 ${WIDTH}×${HEIGHT}）…"
  sips -c "$side" "$side" "$PNG" --out "$PNG" >/dev/null
  WIDTH=$side
  HEIGHT=$side
fi
if [[ "$WIDTH" != "1024" || "$HEIGHT" != "1024" ]]; then
  echo "调整源图尺寸为 1024×1024（当前 ${WIDTH}×${HEIGHT}）…"
  sips -z 1024 1024 "$PNG" --out "$PNG" >/dev/null
fi

rm -rf "$ICONSET"
mkdir -p "$ICONSET"

for size in 16 32 128 256 512; do
  sips -z $size $size "$PNG" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z $double $double "$PNG" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET" -o "$ICNS"
rm -rf "$ICONSET"
echo "已生成: $ICNS"
