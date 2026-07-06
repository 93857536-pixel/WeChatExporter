#!/bin/bash
# 更新 GitHub 仓库 About 信息（需本机 gh 已登录且有 repo 管理权限）
set -euo pipefail

REPO="${1:-93857536-pixel/WeChatExporter}"

gh repo edit "$REPO" \
  --description "微信聊天记录导出 | macOS DMG + Windows | 本地运行 | Swift + WPF" \
  --homepage "https://github.com/93857536-pixel/WeChatExporter/releases/latest"

gh repo edit "$REPO" \
  --add-topic wechat \
  --add-topic chat-export \
  --add-topic backup \
  --add-topic macos \
  --add-topic windows \
  --add-topic swift \
  --add-topic swiftui \
  --add-topic wpf \
  --add-topic privacy \
  --add-topic export

echo "已更新 $REPO 的描述、主页链接与 Topics"
