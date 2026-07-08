# Changelog

All notable changes to this project are documented in this file.

## [2.5.1] - 2026-07-08

### Changed
- 单文件 HTML 导出界面美化：深空霓虹 HUD 风格，与 macOS DMG 安装界面视觉一致（玻璃拟态消息卡片、星点/网格背景、青紫霓虹标题与媒体光晕）

## [2.5.0] - 2026-07-08

### Changed
- 每次导出生成**单个 HTML 文件**（图片、表情、音视频以 base64 内嵌），浏览器打开即可查看全部内容
- 不再在导出目录留下 chat.json / media 等分散文件夹

## [2.4.0] - 2026-07-08

### Added
- 勾选「同时导出媒体」时自动下载聊天中的表情/贴纸（GIF/PNG）到 `media/emojis/`
- macOS 导出时向 wx-cli 传递 `--show-emoji`，保留表情详情

### Changed
- 导出选项文案明确包含「表情」

## [2.3.9] - 2026-07-07

### Fixed
- macOS DMG 背景图无法铺满窗口：修正 1x/2x 背景 DPI（72/144）并合并为 Retina TIFF，Finder 不再只显示左上角

## [2.3.8] - 2026-07-07

### Changed
- macOS DMG 安装包界面美化：自定义背景、图标拖拽布局、卷标图标与固定窗口尺寸

## [2.3.7] - 2026-07-06

### Fixed
- macOS 勾选「同时导出媒体」后显示 0 条：wx-cli 实际输出为「联系人_日期.json」，现已正确统计并复制为 chat.json/txt/csv
- 含媒体导出取消 600 秒超时限制，避免大体积导出被中断
- Windows 同步改进 JSON 消息计数（支持 wrapper 格式）

## [2.3.6] - 2026-07-06

### Added
- **Windows**：会话加载与准备数据进度条（先时间预估，完成后显示实际数量）
- **Windows**：取消会话/初始化超时上限，使用 `-n 999999` 拉取全部会话
- **Windows**：未准备数据时跳过启动自动加载

## [2.3.5] - 2026-07-06

### Added
- 会话加载进度条：先时间预估，拿到总量后按「已加载 / 总数」实时更新
- 分页拉取全部会话（每批 500 条），不再受 120 秒超时限制

### Changed
- 准备数据 / 解密过程同样显示进度条
- wx-cli 长时间任务取消固定超时，改为无上限等待

## [2.3.4] - 2026-07-06

### Fixed
- macOS 加载会话列表超时：移除 `--all`（最多 2 万条），改用 `--limit 10000`，超时延长至 5 分钟
- 未准备数据时不再盲目加载会话，避免首次启动长时间卡住
- wx-cli 执行过程实时输出日志，超时时给出更明确的提示

### Changed
- 解密命令超时延长至 10 分钟；会话查询使用 `--no-server` 直连本地缓存

## [2.3.3] - 2026-07-06

### Fixed
- macOS 启动崩溃：修复 wx-cli 在后台线程回调导致 SwiftUI 菜单栏断言失败（SIGABRT）
- 将自动加载会话列表从 `init` 延迟到界面 `onAppear`，避免启动阶段竞态

### Changed
- 全新科技感应用图标（深青渐变 + 导出箭头）
- 构建脚本不再将 PNG 误当作 icns 使用，确保 Dock/Finder 图标尺寸正确

## [2.3.2] - 2026-07-06

### Added
- App icon bundled in repository (`assets/AppIcon.png`)
- README screenshots, badges, English README, CHANGELOG, CONTRIBUTING
- GitHub Issue templates and CI workflow (Swift + .NET build)
- `scripts/prepare_icon.sh` for macOS icns generation

### Changed
- README reorganized with Release-first install instructions
- `install.sh` documents DMG download and optional `CREATE_DMG=1`

## [2.3.1] - 2026-07-06

### Added
- macOS DMG installer (`WeChatExporter-macOS-arm64.dmg`) with drag-to-Applications layout
- `scripts/create_dmg.sh` for local DMG generation

### Changed
- GitHub Releases now publish DMG as the recommended macOS download

## [2.3.0] - 2026-07-06

### Added
- Windows self-contained Release build (no .NET runtime required)
- Optional media export toggle on macOS and Windows
- Readiness status banner in both UIs
- Windows administrator detection and one-click restart as administrator

### Changed
- First launch no longer shows error dialogs when data is not prepared yet
- Improved bootstrap and session loading UX

## [2.2.0] - 2026-07-06

### Added
- Windows WPF application with bundled jackwener/wx-cli
- GitHub Actions automated Release builds for macOS and Windows
- Bundled wx-cli inside macOS app (pandorafuture/wx-cli)

### Changed
- macOS app prefers bundled CLI over system-installed wx-cli

## [2.1.0] - Initial public release

### Added
- Native macOS SwiftUI chat exporter
- TXT / CSV / JSON export
- LLDB key capture and SQLCipher decryption fallback backend
- wx-cli integration for session list and export
