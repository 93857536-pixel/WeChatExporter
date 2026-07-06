# WeChatExporter

原生应用，用于导出微信本地聊天记录。

- **macOS 版**：Swift + SwiftUI（见项目根目录）
- **Windows 版**：.NET 8 WPF（见 [`windows/`](windows/) 目录）

支持选择任意联系人或群聊，导出为 TXT / CSV / JSON 格式。

## 下载（推荐）

前往 [GitHub Releases](https://github.com/93857536-pixel/WeChatExporter/releases) 下载预编译版本：

| 平台 | 文件 | 说明 |
|------|------|------|
| macOS (Apple Silicon) | `WeChatExporter-macOS-arm64.zip` | 解压后打开 `.app`，内置 wx-cli |
| Windows (64 位) | `WeChatExporter-Windows-x64.zip` | 解压后运行 `WeChatExporter.exe`，内置 wx.exe |

## 功能

- 图形界面：搜索、多选联系人/群聊
- **内置 wx-cli**：安装即用，无需单独安装命令行工具
- 自动检测微信数据目录
- 通过 LLDB / 内存扫描捕获密钥并解密（微信 4.x SQLCipher）
- 导出聊天记录到本地文件夹

## 系统要求

### macOS

| 项目 | 要求 |
|------|------|
| 系统 | macOS 13 (Ventura) 或更高 |
| 芯片 | Apple Silicon (arm64) |
| 微信 | Mac 版 4.x（已登录并同步过聊天记录） |
| 密钥捕获 | 需关闭 SIP（System Integrity Protection） |

### Windows

| 项目 | 要求 |
|------|------|
| 系统 | Windows 10 / 11（64 位） |
| 运行时 | [.NET 8 Desktop Runtime](https://dotnet.microsoft.com/download/dotnet/8.0)（Release 包需安装） |
| 微信 | PC 版 4.x（已登录并同步过聊天记录） |
| 权限 | 首次「准备数据」建议以管理员身份运行 |

> **隐私说明**：本工具仅在本地运行，不会上传任何聊天数据或密钥。

## 安装

### macOS

#### 方式一：从源码构建

```bash
git clone https://github.com/93857536-pixel/WeChatExporter.git
cd WeChatExporter
./install.sh
```

安装完成后，应用会出现在：

- `~/Desktop/WeChatExporter.app`
- `/Applications/WeChatExporter.app`

应用已内置 `wx-cli`（`Contents/Resources/wx-cli`），**无需**再单独安装命令行工具。

#### 方式二：仅编译不安装

```bash
./build_app.sh
# 产物：./WeChatExporter.app
```

### Windows

详见 [`windows/README.md`](windows/README.md)。

```powershell
cd windows
.\install.ps1
```

Windows 版内置 `wx.exe`，安装后无需单独安装 CLI。首次使用建议以管理员身份运行。

## 使用（macOS）

1. 打开 **WeChatExporter**
2. 首次使用点击 **「准备数据」**（会通过 LLDB 重启微信并捕获密钥，随后解密数据库）
3. 在左侧列表搜索并选择联系人或群聊（⌘ 可多选）
4. 点击 **「导出选中」**
5. 默认导出目录：`~/Downloads/微信聊天记录导出/`

若系统提示「无法验证开发者」，请 **右键 → 打开 → 确认打开**。

## 使用（Windows）

1. 解压 Release 包，**右键以管理员身份运行** `WeChatExporter.exe`（首次推荐）
2. 点击 **「准备数据」**
3. 选择联系人（Ctrl 多选）→ **「导出选中」**
4. 默认导出目录：`Downloads\微信聊天记录导出\`

## 项目结构

**macOS**

```
Sources/WeChatExporter/
├── WeChatExporterApp.swift      # 应用入口
├── Views/ContentView.swift      # SwiftUI 界面
├── ViewModels/AppViewModel.swift
├── Models/ContactItem.swift
└── Services/
    ├── AppPaths.swift           # 路径检测与迁移
    ├── CryptoService.swift      # SQLCipher 解密
    ├── KeyCaptureService.swift  # LLDB 密钥捕获
    ├── DatabaseService.swift
    ├── ContactStore.swift       # 联系人/会话列表
    ├── ChatExporter.swift       # 导出 TXT/CSV/JSON
    ├── WxCliService.swift       # 内置 wx-cli 调用
    └── SQLiteDatabase.swift

scripts/
└── bundle_wx_cli.sh             # 构建时下载并打包 wx-cli
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

## 免责声明

- 本工具仅供个人备份自己的聊天记录，请勿用于非法用途
- 微信数据库格式可能随版本更新而变化，不保证兼容所有版本
- 使用本工具的风险由使用者自行承担

## License

MIT
