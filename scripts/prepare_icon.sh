#!/bin/bash
# 从 assets/AppIcon.png 生成 macOS AppIcon.icns（需在 macOS 上运行）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PNG="$ROOT/assets/AppIcon.png"
ICONSET="$ROOT/assets/AppIcon.iconset"
ICNS="$ROOT/assets/AppIcon.icns"

if [[ ! -f "$PNG" ]]; then
  echo "跳过图标：未找到 $PNG"
  exit 0
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "跳过 icns 生成：当前非 macOS 环境"
  exit 0
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
