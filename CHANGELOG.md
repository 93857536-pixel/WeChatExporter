# Changelog

All notable changes to this project are documented in this file.

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
