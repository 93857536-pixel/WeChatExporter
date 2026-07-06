# Contributing

感谢关注 WeChatExporter！

## 报告问题

- Bug：请使用 [Bug Report](https://github.com/93857536-pixel/WeChatExporter/issues/new?template=bug_report.yml) 模板
- 功能建议：请使用 [Feature Request](https://github.com/93857536-pixel/WeChatExporter/issues/new?template=feature_request.yml) 模板

提交 Issue 时请附上：平台、系统版本、微信版本、应用版本、复现步骤和日志。

## 开发

### macOS

```bash
swift build
./build_app.sh
bash scripts/create_dmg.sh
```

### Windows

```powershell
cd windows
./build.ps1
```

## 发版

维护者推送 `v*` tag 后，GitHub Actions 会自动构建并发布 Release。

## 原则

- 仅用于备份**本人**聊天记录
- 不上传用户数据或密钥
- 保持改动聚焦，匹配现有代码风格
