# Changelog

All notable changes to this project are documented in this file.

## [2.21.6] - 2026-11-07

### Fixed（云备份登录/注册间歇性「安全连接失败 / TLS 错误」）

- **修复: 双端云备份鉴权与全部 HTTP 请求增加传输层指数退避重试（macOS + Windows）**
  - 现象: 云备份登录/注册/发验证码间歇报「安全连接失败 / 无法建立安全连接」（Windows）或 TLS 握手错误（macOS），服务端与 CF 隧道实际健康
  - Root cause: 链路固有特性——GFW 中间盒对未备案域名（linminhao.top 经 CF 隧道过国内）间歇性 TLS 重置，单次握手被 RST 即失败；且旧代码鉴权链路（sendCode/login/register）与 Windows 全部请求**无传输层重试**，撞一次失败窗口直接弹错（分块上传/下载虽有重试，但鉴权没有）
  - Fix: 双端对称新增传输层重试——macOS `CloudBackupAPI.withTransportRetry`（1/2/4/8/16s 共 5 次，仅瞬时 URLError/连接失败/5xx/429 重试，4xx 语义错误与用户取消立即上抛，重试耗尽给可操作提示 `networkExhausted`）；Windows `CloudBackupClient.SendWithRetryAsync`（1/2/4/8s 共 5 次，429 尊重 retryAfterSec，POST/DELETE 每次 attempt 重建请求避免复用已发送 Content，超时取消与用户取消区分处理）
  - 行为: 用户点一次登录/注册即可自动跨过间歇失败窗口；持续不可达时给出「网络连接不稳定（多次重试仍失败）」友好文案而非底层 TLS 技术细节

## [2.21.5] - 2026-11-06

### Fixed（issue #45: 导出含日历内容时 macOS 崩溃 SIGTRAP）

- **修复: ICS 行折叠越界崩溃（三端）**
  - #45: macOS 导出含日历/ICS 内容的消息时 `CalendarExtractService.foldIcsLine` 数组越界（Array index out of range → SIGTRAP 闪退）
  - Root cause: 折叠循环 `end = offset + budget` 超出字节尾时，回退循环 `while end < count` 不执行 → `bytes[offset..<end]` 越界；任何 SUMMARY/DESCRIPTION 行超 75 字节（中文约 25 字）必触发
  - Fix: `end` 钳到 `min(offset+budget, count)` 再回退 UTF-8 字符边界；macOS（Swift）与 Windows（C# 同款）同修；Linux（Rust）补齐缺失的行折叠（此前超长行违反 RFC 5545 75-octet 规则）
  - 行为验证: 修复前基线在真实数据上复现 SIGTRAP；修复后 mac 端到端 PASS（maxLineOctets=75）、Win 端到端 PASS、Linux cargo 回归测试 21/21 通过
## [2.21.4] - 2026-10-30

### Fixed（issue #44: 导出后缺少 .html 文件）

- **修复: Single-file HTML export kembali ke workflow** (v2.12.0 menghapusnya)
  - #44: User melaporkan bahwa setelah export, tidak ada file `[kontak].html`, `transcript.txt`, atau `.ocr`
  - Root cause: Di v2.12.0, `SingleFileExporter.writeHTML()` dihapus dari workflow utama saat migrasi ke 3 mode export (categorized/textOnly/all)
  - Fix: Tambahkan kembali `SingleFileExporter.writeHTML()` untuk setiap kontak setelah mode export (default: enabled)
  - Opsi `singleFileHtmlEnabled` default = true (retrofit: existing users tanpa setting baru = false, jadi perlu enable manual)
  - Toggle UI baru di SettingsView: "单文件 HTML 导出" (doc.fill icon)
  - `transcript.txt`: TIDAK ADA BUG - user tidak punya whisper.cpp, jadi skip normal
  - `.ocr.txt`: DIBUAT dengan benar, masuk ke folder "其他" di categorized mode - user mungkin tidak cari di situ

### Changed

- Default behavior: single-file HTML export ON by default untuk user baru (existing users perlu toggle on manual)
- SettingsView: Tambah section "单文件 HTML 导出" dengan toggle dan description

### Added

- `ExportModePreferences.singleFileHtmlEnabled` (UserDefaults key: `export.singleFileHtml`, default: true)
- `AppViewModel.singleFileHtmlEnabled` + `setSingleFileHtmlEnabled()`
- Settings UI toggle untuk single-file HTML export

### Files changed

- `Sources/WeChatExporter/Models/ExportMode.swift` (+2 properties)
- `Sources/WeChatExporter/ViewModels/AppViewModel.swift` (+3 lines)
- `Sources/WeChatExporter/Views/SettingsView.swift` (+1 line)

### Build

- `build_app.sh`: 2.21.3 → 2.21.4, Build 37 → 38
- `Windows/WeChatExporter.Windows.csproj`: 2.21.3 → 2.21.4

---
