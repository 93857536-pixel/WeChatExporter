# Changelog

All notable changes to this project are documented in this file.

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
