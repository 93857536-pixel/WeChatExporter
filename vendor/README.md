# Vendored CLI binaries

These binaries are bundled into WeChatExporter releases so the app does not
depend on a separate `wx-cli` GitHub repository at build time.

| Path | Platform | Notes |
|------|----------|-------|
| `macos/wx-cli` | macOS universal（x86_64 + arm64） | Built from pandorafuture/wx-cli (open-source Rust, main HEAD ≥ v0.7.4) for both Apple targets and lipo-merged: native on Intel Macs **and** Apple Silicon. Key extraction accepts WeChat 4.1.7 and newer (allowlist removed upstream; 4.1.12+ included). |
| `windows/wx.exe` | Windows x64 | Previously shipped in WeChatExporter v2.6.2 (jackwener/wx-cli upstream is DMCA-unavailable) |

`scripts/bundle_wx_cli.sh` and `windows/scripts/bundle_wx_cli.ps1` copy from here first.
