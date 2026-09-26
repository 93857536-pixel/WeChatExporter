# Vendored CLI binaries

These binaries are bundled into WeChatExporter releases so the app does not
depend on a separate `wx-cli` GitHub repository at build time.

| Path | Platform | Notes |
|------|----------|-------|
| `macos/wx-cli` | macOS x86_64（M 系经 Rosetta 2 运行） | Based on pandorafuture/wx-cli 0.7.2; version allowlist extended to WeChat 4.1.7–4.1.11. x86_64 single-arch: native on Intel Macs, runs on Apple Silicon via Rosetta 2. |
| `windows/wx.exe` | Windows x64 | Previously shipped in WeChatExporter v2.6.2 (jackwener/wx-cli upstream is DMCA-unavailable) |

`scripts/bundle_wx_cli.sh` and `windows/scripts/bundle_wx_cli.ps1` copy from here first.
