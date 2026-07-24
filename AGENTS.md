# Agent 约定

## 发版

功能开发完成、测试/CI 通过后，**直接打 tag 并推送到 GitHub Release**，无需再等用户催促发版。

步骤：

1. 更新 `CHANGELOG.md`、版本号（`build_app.sh` 的 `APP_VERSION`、Windows `.csproj` 的 `<Version>`）
2. 提交并推送功能分支 / 合入相关改动
3. 在对应提交上创建并推送 annotated tag，例如：
   ```bash
   git tag -a vX.Y.Z -m "WeChatExporter vX.Y.Z …"
   git push origin vX.Y.Z
   ```
4. 推送 `v*` tag 会触发 `.github/workflows/release.yml`，自动构建 macOS/Windows 包并发布到 Releases
5. 确认 Release 页面已生成且含：
   - `WeChatExporter-macOS-arm64.dmg`
   - `WeChatExporter-macOS-arm64.zip`
   - `WeChatExporter-Windows-x64.zip`
