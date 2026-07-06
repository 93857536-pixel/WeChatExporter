# WeChatExporter — Windows 版

原生 Windows 桌面应用，用于导出 **微信 PC 版 4.x** 本地聊天记录。

基于 **.NET 8 WPF** 构建，内置 [jackwener/wx-cli](https://github.com/jackwener/wx-cli)，安装即用，无需单独安装 CLI。

## 功能

- 图形界面：搜索、多选联系人/群聊
- **内置 wx-cli**：密钥扫描、数据库解密、导出一体化
- 导出格式：**TXT / CSV / JSON**
- 默认导出目录：`Downloads\微信聊天记录导出\`

## 系统要求

| 项目 | 要求 |
|------|------|
| 系统 | Windows 10 / 11（64 位） |
| 运行时 | [.NET 8 Desktop Runtime](https://dotnet.microsoft.com/download/dotnet/8.0) |
| 微信 | PC 版 4.x（已登录并同步过聊天记录） |
| 权限 | 首次「准备数据」建议 **以管理员身份运行**（读取微信进程内存） |

> **隐私说明**：本工具仅在本地运行，不会上传任何聊天数据或密钥。

## 安装

### 方式一：下载 Release（推荐）

前往 [GitHub Releases](https://github.com/93857536-pixel/WeChatExporter/releases)，下载 `WeChatExporter-Windows-x64.zip`，解压后运行 `WeChatExporter.exe`。

### 方式二：从源码构建

在 PowerShell 中执行：

```powershell
cd windows
.\install.ps1
```

安装完成后，桌面会出现 `WeChatExporter` 文件夹，内含 `WeChatExporter.exe` 与内置 `wx.exe`。

### 方式二：仅构建

```powershell
cd windows
.\build.ps1
# 产物：windows\dist\WeChatExporter\
```

## 使用

1. **右键 → 以管理员身份运行** `WeChatExporter.exe`（首次推荐）
2. 点击 **「准备数据」**（自动扫描密钥并解密数据库）
3. 在左侧列表搜索并选择联系人或群聊（Ctrl 多选）
4. 点击 **「导出选中」**

## 项目结构

```
windows/
├── WeChatExporter.Windows/     # WPF 主程序
│   ├── MainWindow.xaml           # 界面
│   ├── ViewModels/               # 视图模型
│   ├── Services/WxCliService.cs  # 内置 wx-cli 调用
│   └── Models/                   # 数据模型
├── scripts/bundle_wx_cli.ps1     # 构建时下载 wx-cli
├── build.ps1                     # 构建脚本
└── install.ps1                   # 安装脚本
```

## 数据目录

| 用途 | 路径 |
|------|------|
| 微信加密数据库 | `%USERPROFILE%\Documents\xwechat_files\<账号>\db_storage\` |
| wx-cli 配置与密钥 | `%USERPROFILE%\.wx-cli\` |
| wx-cli 解密缓存 | `%USERPROFILE%\.wx-cli\cache\` |
| 导出结果 | `%USERPROFILE%\Downloads\微信聊天记录导出\` |

## 常见问题

**提示密钥扫描失败 / init 失败**

1. 确认微信 PC 版已登录并在运行
2. 右键 **以管理员身份运行** WeChatExporter
3. 重新点击「准备数据」

**提示未找到 wx-cli**

重新运行 `install.ps1` 或 `build.ps1`，确认 `wx.exe` 与 `WeChatExporter.exe` 在同一目录。

**会话列表为空**

先点击「准备数据」，完成后点击「刷新」。

## 免责声明

- 本工具仅供个人备份自己的聊天记录，请勿用于非法用途
- 微信数据库格式可能随版本更新而变化，不保证兼容所有版本
- 使用本工具的风险由使用者自行承担

## License

MIT
