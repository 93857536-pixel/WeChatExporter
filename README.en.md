# WeChatExporter

[![Release](https://img.shields.io/github/v/release/93857536-pixel/WeChatExporter?label=release)](https://github.com/93857536-pixel/WeChatExporter/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Native desktop app to export **your own** WeChat chat history locally. No cloud upload, no key exfiltration.

**中文文档:** [README.md](README.md)

## Download

Get the latest build from **[GitHub Releases](https://github.com/93857536-pixel/WeChatExporter/releases/latest)**:

| Platform | File | Notes |
|----------|------|-------|
| macOS (Apple Silicon) | `WeChatExporter-macOS-arm64.dmg` | Drag to Applications |
| macOS (alt) | `WeChatExporter-macOS-arm64.zip` | Extract and open `.app` |
| Windows (x64) | `WeChatExporter-Windows-x64.zip` | Self-contained, no .NET install |

![Main UI](docs/screenshots/main-ui.png)

## Features

- GUI: search, multi-select contacts/groups
- Bundled wx-cli (no separate CLI install)
- Readiness banner for first-time setup
- Two export modes: single self-contained HTML, or folder bundle (text doc + images/audio/video/emojis)
- Optional media export for HTML mode (best-effort)
- Export TXT / CSV / JSON

## Requirements

### macOS
- macOS 13+, Apple Silicon (arm64)
- WeChat Mac 4.x, logged in
- SIP disabled for key capture

### Windows
- Windows 10/11 x64
- WeChat PC 4.x, logged in
- Run as Administrator recommended for first setup

## Quick Start

1. Download the release for your platform
2. Open the app
3. Click **Prepare Data** (first time only)
4. Select chats and click **Export**

## Build from Source

```bash
# macOS
./build_app.sh
bash scripts/create_dmg.sh

# Windows
cd windows && ./build.ps1
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Please use issue templates for bugs and feature requests.

## Disclaimer

For personal backup of **your own** data only. WeChat schema may change; compatibility not guaranteed.

## License

MIT
