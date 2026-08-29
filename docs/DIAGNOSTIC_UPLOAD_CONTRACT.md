# WeChatExporter 诊断日志上传 — 双平台实现契约 (v2.14.0)

## 1. 功能需求
- 首次启动弹「诊断日志上传」条款窗:同意 / 不同意
  - 同意 → 报错时自动上传诊断日志
  - 不同意 → 任何情况下都不上传(功能完全不受影响)
  - 未决定前默认不弹窗干扰?否——**必须弹窗**,用户明确选择后才继续
- 设置里提供开关(可随时更改,即时生效)
- 导出/准备数据/加载会话任一环节报错时,自动上传诊断信息
- 上传必须**静默**:失败不影响用户操作,不弹错误框,仅写本地日志

## 2. 上传端点与协议
- URL: `https://linminhao.top/diag/v1/diag`（经 Cloudflare Tunnel 443 → 服务器 127.0.0.1:8082）
- ⚠️ 不要直连 http://112.126.79.9:8082 —— 阿里云云盾拦截非 80/443 端口公网 HTTP（TCP 握手假通但 empty reply）
- Method: POST, Content-Type: application/json
- Header: `x-diag-token: wxexporter-diag-2026`
- Timeout: 5 秒,失败静默(不重试、不阻塞)
- 请求体 JSON:
```json
{
  "app": "WeChatExporter",
  "platform": "windows" | "macos",
  "version": "2.14.0",
  "build": "30",
  "os": "操作系统版本字符串",
  "timestamp": "ISO8601 本地时间",
  "stage": "prepare | load_sessions | export | other",
  "error": "错误消息(截断 2000 字符)",
  "logs": "运行日志尾部(截断 8000 字符, 最后约 50 行)"
}
```
- 期望响应: HTTP 200 + `{"ok":true}` (不解析响应内容也行)

## 3. 条款文本(两平台完全一致)
标题:诊断日志上传

正文:
为了让导出工具越来越稳定,当导出过程中发生错误时,本应用可以自动将以下诊断信息发送到开发者服务器:
- 应用版本与操作系统版本
- 错误消息与错误发生时的操作步骤
- 程序运行日志的最后部分

这些信息仅包含技术诊断数据,不包含你的聊天内容、联系人信息、账号信息或任何个人隐私数据。

- 同意:导出报错时自动上传诊断信息,用于开发者分析并修复问题
- 不同意:应用功能完全不受影响,任何情况下都不会上传任何数据

你随时可以在「设置」中更改此选项。

按钮: 同意并继续 / 不同意

## 4. 存储
- macOS: UserDefaults key `diagnostics.consented` (Bool, 未设置=未选择)
- Windows: `%APPDATA%\WeChatExporter\settings.json` 文件, `{"diagnostics_consented": true/false}` (未设置=未选择)

## 5. 设置项文案
- macOS 设置面板(导出 tab 或新增 tab):Toggle「自动上传诊断日志(报错时)」
- Windows 导出设置 GroupBox 加 CheckBox:「报错时自动上传诊断日志」

## 6. 文件规划
### macOS (SwiftUI)
- 新增: Sources/WeChatExporter/Services/DiagnosticUploader.swift
  - `enum DiagnosticUploader` : consent 读取/设置/清除, `static func reportIfAllowed(stage:error:logs:)`
  - 用 URLSession, POST JSON, timeout 5s, 失败静默
- 修改: WeChatExporterApp.swift — 启动时若未选择则显示条款 sheet
- 修改: AppViewModel.swift — 所有 catch 的 presentError 处调用 `DiagnosticUploader.reportIfAllowed(...)`;新增 `@Published var showConsent = false`
- 修改: SettingsView.swift — 加开关
### Windows (WPF)
- 新增: Services/DiagnosticUploader.cs (同逻辑, HttpClient, 5s timeout, 失败静默)
- 新增: ConsentWindow.xaml + .cs (条款弹窗)
- 修改: MainWindow.xaml.cs — 启动时若未选择显示 ConsentWindow
- 修改: MainViewModel.cs — 所有 catch 的 ShowError 处调用 `await DiagnosticUploader.ReportIfAllowedAsync(...)` (fire-and-forget 或非阻塞)
- 修改: MainWindow.xaml — 导出设置 GroupBox 加 CheckBox

## 7. 验证
- macOS: `swift build --disable-sandbox -c release` 必须 Build complete
- Windows: `dotnet build windows/WeChatExporter.Windows/WeChatExporter.Windows.csproj -c Release -p:EnableWindowsTargeting=true` 必须成功
- 上传可用本地 mock 验证: `python3 -m http.server 8082` 起个临时服务看是否收到 POST(可选)
- 条款弹窗状态:首次启动显示,选择后不再显示;设置开关可反转

## 8. 注意事项
- 不改动任何现有业务逻辑、版本号(版本号由主流程统一同步)
- 保持项目现有代码风格(参考 UpdateService.swift / UpdatePreferences 模式;WPF 参考现有 Services 风格)
- WPF 隐式 using 不含 System.IO —— 新文件必须显式 using System.IO;若与 WinForms 混用需注意类型歧义
- 日志截断:error 2000 字符、logs 8000 字符(超出截断,避免超大 body)
- 上传不携带任何聊天内容/联系人/密钥
