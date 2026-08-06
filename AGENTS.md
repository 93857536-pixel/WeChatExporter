# 项目工作流约定（Agent 必读）

## 硬性规则：每次完成修改后必须发布 Releases

**任何一次代码修改完成后（包括 bug 修复、功能开发、UI 调整、文档改动且影响发布产物时），必须执行以下发布流程，不得遗漏：**

1. **统一更新版本号**（三处必须同步）：
   - macOS：`build_app.sh` 中的 `APP_VERSION` / `APP_BUILD`
   - Windows：`windows/WeChatExporter.Windows/WeChatExporter.Windows.csproj` 中的 `<Version>`
   - 文档：`CHANGELOG.md` 顶部添加新版本条目（含日期、Added/Fixed 分组）
   - 版本号规则：功能/UI 变化 → 次版本号 +1（如 2.10.0 → 2.11.0）；纯修复 → 补丁号 +1（如 2.10.1）；Build 号每次递增

2. **本地编译验证**：
   - macOS：`swift build --disable-sandbox -c release`（须 Build complete）
   - Windows：`dotnet build windows/WeChatExporter.Windows/WeChatExporter.Windows.csproj -c Release`

3. **提交并打标签**：
   ```bash
   git add -A
   git commit -m "类型(scope): 描述 (vX.Y.Z)"
   git tag vX.Y.Z
   git push origin main --tags
   ```

4. **等待 GitHub Actions 自动发布**（`.github/workflows/release.yml` 监听 `v*` 标签）：
   - 触发后自动构建：macOS DMG + ZIP、Windows ZIP
   - 自动创建 GitHub Release 并上传资产
   - **必须验证 Actions 运行成功**：`gh run watch` 或查询 `gh run list --branch main` 确认三个 job（build-macos / build-windows / release）全部成功，且 Release 资产已出现

5. **通知用户**：告知新版本号、Release 链接、以及核心变更摘要

## 项目要点

- 仓库：`93857536-pixel/WeChatExporter`（GitHub）
- 双平台：macOS（SwiftUI，`Sources/`）+ Windows（WPF，`windows/`）
- 发布机制：推 `v*` tag 触发 GitHub Actions 自动打包上传 Releases，**无需手动上传资产**
- 更新通道：应用内自动更新从 GitHub Releases 下载 `WeChatExporter-macOS-arm64.dmg`
- 常用脚本：`./build_app.sh`（macOS 打包）、`scripts/create_dmg.sh`（DMG）、`windows/build.ps1`（Windows）
