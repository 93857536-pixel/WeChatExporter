# Vendored CLI binaries

These binaries are bundled into WeChatExporter releases so the app does not
depend on a separate `wx-cli` GitHub repository at build time.

| Path | Platform | Notes |
|------|----------|-------|
| `macos/wx-cli` | macOS arm64 | Based on pandorafuture/wx-cli 0.7.2; version allowlist extended to WeChat 4.1.7–4.1.11 |
| `windows/wx.exe` | Windows x64 | Previously shipped in WeChatExporter v2.6.2 (jackwener/wx-cli upstream is DMCA-unavailable) |

`scripts/bundle_wx_cli.sh` and `windows/scripts/bundle_wx_cli.ps1` copy from here first.
