# Changelog

All notable changes to this project are documented in this file.

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
