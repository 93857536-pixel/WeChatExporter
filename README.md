# WeChatExporter

原生 macOS 应用，用于导出微信 Mac 版本地聊天记录。

基于 Swift + SwiftUI 构建，支持选择任意联系人或群聊，导出为 TXT / CSV / JSON 格式。

## 功能

- 图形界面：搜索、多选联系人/群聊
- **内置 wx-cli**：安装即用，无需单独安装命令行工具
- 自动检测微信数据目录
- 通过 LLDB 捕获数据库密钥并解密（微信 4.x SQLCipher）
- 导出聊天记录到本地文件夹

## 系统要求

| 项目 | 要求 |
|------|------|
| 系统 | macOS 13 (Ventura) 或更高 |
| 芯片 | Apple Silicon (arm64) |
| 微信 | Mac 版 4.x（已登录并同步过聊天记录） |
| 密钥捕获 | 需关闭 SIP（System Integrity Protection） |

> **隐私说明**：本工具仅在本地运行，不会上传任何聊天数据或密钥。导出的文件保存在你的 Mac 上。

## 安装

### 方式一：从源码构建

```bash
git clone https://github.com/93857536-pixel/WeChatExporter.git
cd WeChatExporter
./install.sh
```

安装完成后，应用会出现在：

- `~/Desktop/WeChatExporter.app`
- `/Applications/WeChatExporter.app`

应用已内置 `wx-cli`（`Contents/Resources/wx-cli`），**无需**再单独安装命令行工具。

### 方式二：仅编译不安装

```bash
./build_app.sh
# 产物：./WeChatExporter.app
```

## 使用

1. 打开 **WeChatExporter**
2. 首次使用点击 **「准备数据」**（会通过 LLDB 重启微信并捕获密钥，随后解密数据库）
3. 在左侧列表搜索并选择联系人或群聊（⌘ 可多选）
4. 点击 **「导出选中」**
5. 默认导出目录：`~/Downloads/微信聊天记录导出/`

若系统提示「无法验证开发者」，请 **右键 → 打开 → 确认打开**。

## 项目结构

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

## 数据目录

| 用途 | 路径 |
|------|------|
| 微信加密数据库 | `~/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files/<账号>/db_storage/` |
| 应用工作目录 | `~/Library/Application Support/WeChatExporter/<账号>/` |
| 导出结果 | `~/Downloads/微信聊天记录导出/` |

## 常见问题

**提示 SQL 或数据库错误**

点击「准备数据」重新解密。若仍失败，请确认微信已登录且 SIP 已关闭。

**密钥捕获失败**

1. 确认微信处于登录状态
2. 确认 SIP 已关闭：`csrutil status`
3. 重新点击「准备数据」

**应用打不开**

在终端执行：

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
