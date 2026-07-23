#!/bin/bash
# 下载并解压 wx-cli 到指定目录，供 WeChatExporter.app 内置使用。
# 优先使用本地已编译二进制：LOCAL_WX_CLI=/path/to/wx-cli
set -euo pipefail

DEST_DIR="${1:?用法: bundle_wx_cli.sh <目标目录>}"
WX_CLI_VERSION="${WX_CLI_VERSION:-v0.7.2-wechat411}"
WX_CLI_REPO="${WX_CLI_REPO:-93857536-pixel/wx-cli}"
ASSET="wx-cli-${WX_CLI_VERSION}-macos-arm64.tar.gz"
URL="https://github.com/${WX_CLI_REPO}/releases/download/${WX_CLI_VERSION}/${ASSET}"

mkdir -p "$DEST_DIR"
DEST_BIN="$DEST_DIR/wx-cli"

if [[ -n "${LOCAL_WX_CLI:-}" && -x "${LOCAL_WX_CLI}" ]]; then
  cp "${LOCAL_WX_CLI}" "$DEST_BIN"
  chmod +x "$DEST_BIN"
  echo "已写入本地 wx-cli：$DEST_BIN （来自 ${LOCAL_WX_CLI}）"
  exit 0
fi

if [[ -x "$DEST_BIN" && "${FORCE_BUNDLE_WX_CLI:-0}" != "1" ]]; then
  echo "wx-cli 已存在：$DEST_BIN"
  exit 0
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "下载内置 wx-cli ${WX_CLI_VERSION}（${WX_CLI_REPO}）…"
curl -fsSL --retry 3 --retry-delay 2 -o "$TMP_DIR/$ASSET" "$URL"

echo "解压 wx-cli…"
tar -xzf "$TMP_DIR/$ASSET" -C "$TMP_DIR"

if [[ -f "$TMP_DIR/wx-cli" ]]; then
  SRC="$TMP_DIR/wx-cli"
elif [[ -f "$TMP_DIR/wx-cli/wx-cli" ]]; then
  SRC="$TMP_DIR/wx-cli/wx-cli"
else
  SRC="$(find "$TMP_DIR" -type f -name wx-cli | head -1)"
fi

if [[ -z "$SRC" || ! -f "$SRC" ]]; then
  echo "错误：未在压缩包中找到 wx-cli 可执行文件"
  exit 1
fi

cp "$SRC" "$DEST_BIN"
chmod +x "$DEST_BIN"
echo "已写入：$DEST_BIN"
