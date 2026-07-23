#!/bin/bash
# 将内置 wx-cli 写入目标目录（优先使用仓库 vendor/macos/wx-cli）。
# 可选覆盖：LOCAL_WX_CLI=/path/to/wx-cli
set -euo pipefail

DEST_DIR="${1:?用法: bundle_wx_cli.sh <目标目录>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR_BIN="$ROOT/vendor/macos/wx-cli"

mkdir -p "$DEST_DIR"
DEST_BIN="$DEST_DIR/wx-cli"

if [[ -n "${LOCAL_WX_CLI:-}" && -x "${LOCAL_WX_CLI}" ]]; then
  cp "${LOCAL_WX_CLI}" "$DEST_BIN"
  chmod +x "$DEST_BIN"
  echo "已写入本地 wx-cli：$DEST_BIN （来自 ${LOCAL_WX_CLI}）"
  exit 0
fi

if [[ -x "$VENDOR_BIN" ]]; then
  cp "$VENDOR_BIN" "$DEST_BIN"
  chmod +x "$DEST_BIN"
  echo "已写入内置 wx-cli：$DEST_BIN （来自 vendor/macos/wx-cli）"
  exit 0
fi

echo "错误：未找到 vendor/macos/wx-cli，且未设置 LOCAL_WX_CLI" >&2
echo "请确认仓库包含 vendor/macos/wx-cli，或导出 LOCAL_WX_CLI=/path/to/wx-cli" >&2
exit 1
