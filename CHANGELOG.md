# Changelog

All notable changes to this project are documented in this file.

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
