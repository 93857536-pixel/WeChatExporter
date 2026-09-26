# WeChatExporter

[![Release](https://img.shields.io/github/v/release/93857536-pixel/WeChatExporter?label=release)](https://github.com/93857536-pixel/WeChatExporter/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Windows-lightgrey)](https://github.com/93857536-pixel/WeChatExporter)

原生应用，用于在本地导出**自己的**微信聊天记录。完全离线运行，不上传数据或密钥。

**English README:** [README.en.md](README.en.md)

- **macOS 版**：Swift + SwiftUI，提供 DMG 安装包
- **Windows 版**：.NET 8 WPF，自包含 zip（无需安装 .NET）

![主界面预览](docs/screenshots/main-ui.png)

## 下载（推荐）

前往 **[GitHub Releases](https://github.com/93857536-pixel/WeChatExporter/releases/latest)** 下载最新版：

| 平台 | 文件 | 说明 |
|------|------|------|
| macOS (Apple Silicon / Intel) | `WeChatExporter-macOS-universal.dmg` | 打开 DMG，拖到「应用程序」即可安装（universal 双芯片原生） |
| macOS (备用) | `WeChatExporter-macOS-universal.zip` | 解压后打开 `.app` |
| Windows (64 位) | `WeChatExporter-Windows-x64.zip` | 解压后运行 `WeChatExporter.exe`，**自包含，无需安装 .NET** |

> 版本更新记录见 [CHANGELOG.md](CHANGELOG.md)

## 功能

- 图形界面：搜索、多选联系人/群聊
- **内置 wx-cli**：安装即用，无需单独安装命令行工具
- **就绪状态提示**：界面顶部显示当前进度（是否已完成「准备数据」）
- **单文件导出**：每个会话生成一个 `.html` 文件，文字与媒体（图片、表情、语音、视频）全部内嵌，浏览器直接打开
- **可选媒体导出**：勾选后将媒体 base64 写入 HTML，并额外导出全部表情包画廊；WXGF 图片会自动尝试转码后显示（体积更大，耗时更长）
- **语音转文字**（双平台，本地离线）：导出媒体时自动用自研 SILK 解码器（内置）+ whisper.cpp 离线转写语音消息，结果以 `.transcript.txt` 侧车保存并在 HTML 中折叠展示；缺少 whisper.cpp 时自动跳过不影响导出
- **图片 OCR**（双平台，本地离线）：导出媒体时对图片做本地离线文字识别（macOS Vision 框架 / Windows Media OCR，中英繁离线），结果以 `.ocr.txt` 侧车保存并在 HTML 中折叠展示
- **聊天统计报告**（双平台）：导出时本地聚合生成单文件 HTML 统计报告（消息总量、发言排行、24 小时活跃分布、月度趋势、媒体构成），无外部依赖可离线打开
- **增量导出**（双平台，默认关）：按「联系人 + 导出目录」记忆时间戳游标，下次只导出新增消息；无新增的会话自动跳过
- **目录导航页 + 全文检索**（双平台）：导出后在目录生成 `index.html`，文件列表导航 + 关键词全文检索（内嵌文本数据，可离线打开）
- **电子书 / 文档版导出**（双平台）：本地聚合 `chat.json` 直接生成阅读版文档，零依赖离线。EPUB 电子书（`联系人_聊天记录.epub`，自实现 stored-ZIP，按月分节 + 发言人/时间戳）+ 文档版（macOS 生成 A4 PDF（CoreText/PingFang SC 渲染），Windows 生成 A4 打印版 HTML（浏览器打印 / 另存 PDF））
- **加密导出**（双平台，默认关）：设置中填写导出密码后，导出目录整体打包加密为单个 `.wxenc` 文件（PBKDF2-SHA256 100k 轮派生密钥 + AES-256-GCM 认证加密），明文目录随即删除；日后在任一端（macOS/Windows 互通）凭密码解密还原完整目录，全程离线、零第三方依赖
- 自动检测微信数据目录
- 通过 LLDB / 内存扫描捕获密钥并解密（微信 4.x SQLCipher）
- 导出 TXT / CSV / JSON

## 系统要求

### macOS

| 项目 | 要求 |
|------|------|
| 系统 | macOS 13 (Ventura) 或更高 |
| 芯片 | Apple Silicon (arm64) + Intel (x86_64) universal，双芯片原生运行 |
| 微信 | Mac 版 4.x（已登录并同步过聊天记录） |
| 密钥捕获 | 需关闭 SIP（System Integrity Protection） |

### Windows

| 项目 | 要求 |
|------|------|
| 系统 | Windows 10 / 11（64 位） |
| 运行时 | 无需安装（v2.3.0+ Release 为自包含包） |
| 微信 | PC 版 4.x（已登录并同步过聊天记录） |
| 权限 | 首次「准备数据」建议以管理员身份运行 |

### 兼容说明

| 组件 | macOS | Windows |
|------|-------|---------|
| 内置 CLI | 仓库 `vendor/macos/wx-cli`（支持微信 4.1.7–4.1.11） | 仓库 `vendor/windows/wx.exe` |
| 微信版本 | 4.x（已验证 4.1.7–4.1.11） | 4.x（4.1.7–4.1.11 直接支持；4.1.12+ 由应用层内存扫密钥兜底） |
| 语音转文字 | 可选：需本机安装 [whisper.cpp](https://github.com/ggml-org/whisper.cpp)（`whisper-cli`）与模型；SILK 解码器已内置 | 可选：需 `whisper-cli.exe` + 模型（设置页可一键下载模型）；SILK 解码器已内置 |
| 图片 OCR | 系统自带（macOS 13+ Vision 框架，离线） | 系统自带（Windows 10/11 Media OCR，离线） |
| 统计报告 / 增量 / 检索 | 纯本地，无额外依赖 | 纯本地，无额外依赖 |
| 电子书 / 文档版 | 纯本地：EPUB（自实现 ZIP）+ A4 PDF（CoreText，PingFang SC） | 纯本地：EPUB（自实现 ZIP）+ A4 打印版 HTML（浏览器打印 / 另存 PDF） |

> 语音转写与图片 OCR 均为「可选增强」：关闭或工具缺失时不影响任何导出功能。

### 发版前微信版本验证流程

发版（bump tag / Release）前，用当前稳定版微信走一遍最小回归，避免 4.x 小版本升级导致 wx-cli 解密回归：

1. **准备数据**：在已登录的最新微信版本上点「准备数据」，确认解密成功、会话列表非空
2. **导出**：任选一个会话（含文字 + 图片 + 语音）导出单文件 HTML，确认 HTML 可打开、媒体显示正常
3. **增强功能**（v2.15.0+）：勾选媒体导出 + 语音转文字 / 图片 OCR / 统计报告 / 增量导出，确认侧车文件（`.transcript.txt` / `.ocr.txt`）与统计报告 HTML、增量游标均生成
4. **电子书 / 文档版**（v2.16.0+）：开启开关后导出，确认 `联系人_聊天记录.epub` 可被阅读器打开、macOS 的 PDF / Windows 的打印版 HTML 内容完整（发言人、时间戳、月度分节）
5. **双平台**：macOS 与 Windows 各跑一遍（Windows 重点看 4.1.12+ 的内存扫密钥兜底路径）
6. 任一环节失败 → 修好再发版，不要带着已知解密失败发 Release

> **隐私说明**：本工具仅在本地运行，不会上传任何聊天数据或密钥。

## 快速开始

### macOS

1. 下载并打开 **`WeChatExporter-macOS-universal.dmg`**
2. 在弹出的安装窗口中，将 **WeChatExporter** 拖到右侧 **「应用程序」** 文件夹
3. 打开应用（若提示无法验证开发者，请 **右键 → 打开**）
4. 点击 **「准备数据」** → 选择联系人 → **「导出选中」**

### Windows

1. 解压 **`WeChatExporter-Windows-x64.zip`**
2. **右键以管理员身份运行** `WeChatExporter.exe`（首次推荐）
3. 点击 **「准备数据」** → 选择联系人 → **「导出选中」**

默认导出目录：
- macOS：`~/Downloads/微信聊天记录导出/`
- Windows：`%USERPROFILE%\Downloads\微信聊天记录导出\`

## 从源码构建

### macOS

```bash
git clone https://github.com/93857536-pixel/WeChatExporter.git
cd WeChatExporter
./install.sh                  # 构建并安装到桌面与 /Applications
# 或
./build_app.sh                # 仅生成 .app
bash scripts/create_dmg.sh    # 生成 DMG
CREATE_DMG=1 ./install.sh     # 安装同时生成 DMG
```

### Windows

详见 [`windows/README.md`](windows/README.md)。

```powershell
cd windows
./install.ps1    # 安装到桌面
./build.ps1      # 仅构建到 dist/
```

## 项目结构

**macOS**

```
Sources/WeChatExporter/     # SwiftUI 应用
scripts/
├── bundle_wx_cli.sh        # 打包内置 wx-cli
├── create_dmg.sh           # 生成带自定义背景的 DMG
├── generate_dmg_background.py  # DMG 背景图生成
└── prepare_icon.sh         # 生成 AppIcon.icns
assets/AppIcon.png          # 应用图标源文件
assets/dmg-background.png      # DMG 背景 1x（660×400 @72dpi）
assets/dmg-background@2x.png   # DMG 背景 2x（1320×800 @144dpi）
docs/screenshots/           # README 截图
```

**Windows** — 见 [`windows/README.md`](windows/README.md)

## 数据目录

| 用途 | macOS | Windows |
|------|-------|---------|
| 微信加密数据库 | `~/Library/Containers/.../xwechat_files/<账号>/db_storage/` | `%USERPROFILE%\Documents\xwechat_files\<账号>\db_storage\` |
| 应用工作目录 | `~/Library/Application Support/WeChatExporter/<账号>/` | `%USERPROFILE%\.wx-cli\` |
| 导出结果 | `~/Downloads/微信聊天记录导出/` | `%USERPROFILE%\Downloads\微信聊天记录导出\` |

## 常见问题

**提示 SQL 或数据库错误**

点击「准备数据」重新解密。若仍失败，请确认微信已登录且 SIP 已关闭（macOS）。

**密钥捕获失败**

1. 确认微信处于登录状态
2. macOS：确认 SIP 已关闭 `csrutil status`；Windows：以管理员身份运行
3. 重新点击「准备数据」

**应用打不开（macOS）**

```bash
xattr -cr /Applications/WeChatExporter.app
codesign --force --deep --sign - /Applications/WeChatExporter.app
```

**如何反馈问题**

请使用 [Bug Report 模板](https://github.com/93857536-pixel/WeChatExporter/issues/new?template=bug_report.yml) 提交 Issue。

## 参与贡献

见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 服务器监控（独立仓）

部署后的服务器监控闭环（iOS Monitor App + 服务器端脚本 + 部署文档）已拆至私有仓 `93857536-pixel/WeChatExporterMonitor`（v2.17.0 起）。本仓 `DiagnosticUploader` 的报错日志上传协议与该仓 diag-server 保持兼容。

## 免责声明

- 本工具仅供个人备份**自己的**聊天记录，请勿用于非法用途
- 微信数据库格式可能随版本更新而变化，不保证兼容所有版本
- 使用本工具的风险由使用者自行承担

## License

MIT
