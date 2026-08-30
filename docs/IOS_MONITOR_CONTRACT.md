# WeChatExporter Server Monitor — iOS App 开发契约 (v1.0)

## 1. 功能需求
原生 iOS SwiftUI App,展示服务器运行状态与诊断日志处理进度。4 个 Tab:
1. **概览(Overview)**: 服务器状态卡片(CPU/内存/磁盘)+ 6 个服务指示灯(diagServer/monitorApi/node3000/nginx/cloudflared/hermes)
2. **报错日志(Logs)**: 诊断日志列表(时间/平台/版本/stage/错误摘要/状态徽章),点击进详情页(完整 error + logs 尾部)
3. **修复进度(Fixes)**: 每条日志的解决状态 + Hermes 修复记录列表(auto-fix.log/hermes-fix.log 内容)
4. **Hermes**: 进程状态/模型/安装路径/最近活动

## 2. API 协议(已上线,公网可用)
- Base URL: `https://linminhao.top`
- 所有请求带 Header: `x-diag-token: wxexporter-diag-2026`
- 超时 10s,失败显示友好错误(服务器不可达提示)

### GET /api/status
```json
{
  "ok": true,
  "fetched_at": "ISO8601",
  "system": {
    "cpu": 11.0,
    "memory": {"usedMB": 1389, "totalMB": 1966},
    "disk": {"usedGB": 17.3, "freeGB": 32.6}
  },
  "services": {
    "diagServer": true, "monitorApi": true, "node3000": true,
    "nginx": true, "cloudflared": true, "hermes": false
  },
  "counts": {"inbox": 0, "processing": 0, "resolved": 2, "failed": 0}
}
```

### GET /api/logs?limit=50
```json
{
  "ok": true, "total": 2,
  "logs": [{
    "id": "20260830-165434-4d57e218",
    "status": "pending|resolved|failed",
    "received_at": "ISO8601",
    "app": "WeChatExporter", "platform": "windows|macos|t",
    "version": "2.14.0", "build": "31", "os": "Windows 11",
    "stage": "export|prepare|load_sessions|t",
    "error": "错误摘要(前300字)",
    "error_full": "完整错误",
    "logs_tail": "日志尾部(2000字)",
    "timestamp": "客户端时间"
  }]
}
```

### GET /api/logs/:id
```json
{ "ok": true, "status": "resolved", "data": { ...完整日志对象(含 received_at/remote)... } }
```

### GET /api/hermes
```json
{
  "ok": true,
  "process": "running|stopped",
  "model": "deepseek-v4-flash",
  "install": "C:\\hermes-agent-main",
  "venv": "C:\\Users\\Administrator\\.hermes-agent-venv",
  "last_fix_log": "C:\\WeChatExporterDiag\\hermes-fix.log",
  "recent_fixes": [{ "source": "auto-fix|hermes", "time": "2026-08-30 17:10:18", "text": "..." }]
}
```

### GET /api/history?hours=24 (v2, 2026-08-30 新增)
```json
{
  "ok": true, "hours": 24,
  "points": [{ "t": "ISO8601", "cpu": 3.0, "memUsed": 1497, "memTotal": 1966, "diskUsed": 17.3, "diskFree": 32.6 }]
}
```
- 服务器采集器每 5 分钟写入 history.json(最多 7 天 2000 点),接口降采样到最多 300 点
- hours 范围 1-168

### POST /api/logs/:id/trigger (v2, 2026-08-30 新增)
- 手动触发 Hermes 修复:日志复制回 inbox + 立即运行 auto-fix 计划任务
- 返回: `{ "ok": true, "message": "...", "id": "..." }` 或 404

### POST /api/logs/:id/ack (v2, 2026-08-30 新增)
- 标记已处理:inbox/failed 中的日志移到 processed(写入 acked_at/acked_by)
- 返回: `{ "ok": true, "message": "已标记为处理完成", "id": "..." }` 或 404

### GET /api/fixes (v3, 2026-08-30 新增)
```json
{
  "ok": true,
  "current": { "log_ids": ["..."], "status": "processing|completed", "started_at": "...", "updated_at": "...", "summary": "hermes-fix.log 尾部", "finished_at": "..." } | null,
  "ci": { "id": 123, "name": "CI", "status": "completed", "conclusion": "success", "head_sha": "d696603", "created_at": "...", "html_url": "..." } | null,
  "recent": [{ "source": "auto-fix", "time": "...", "text": "..." }]
}
```

### POST /api/service/:name/restart (v3, 2026-08-30 新增)
- 一键重启服务,白名单: diag-server / monitor-api / cloudflared / nginx
- 返回: `{ "ok": true, "message": "...", "service": "..." }` 或 404(unknown service)

## 3. UI 规格
- 原生 SwiftUI,iOS 17+,iPhone 竖屏
- 深色/浅色自适应(用系统默认即可)
- 下拉刷新(.refreshable)+ 概览页自动 30s 定时刷新
- 状态徽章配色: pending=橙色, processing=蓝色, resolved=绿色, failed=红色
- 服务指示灯: 绿=运行, 红=停止, 灰=未知
- 所有文案中文

## 4. 工程要求
- 目录: `~/Programming/Projects/WeChatExporter/ios/WeChatExporterMonitor/`
  - project.yml(xcodegen)+ Sources/ + Assets.xcassets(AppIcon)
- xcodegen 生成工程;bundle id: `com.linminhao.WeChatExporterMonitor`
- 显式 `SWIFT_VERSION: 5.9`(Xcode 27 beta 默认 Swift 6 会报并发错误)
- `CODE_SIGN_IDENTITY: "-"` 模拟器构建免签名
- 零第三方依赖(纯 URLSession + SwiftUI)
- API 客户端: `APIClient.swift`(enum + async/await,泛型 GET)
- 模型: `Models.swift`(Codable structs 对应上述 JSON)
- 状态管理: `MonitorStore.swift`(ObservableObject, @MainActor, 3 个数据源 status/logs/hermes)
- Keychain 存 token(或简单 UserDefaults 即可——本 App token 非敏感,UserDefaults 可接受)
- 应用图标:用 Assets.xcassets 内置占位(后续可换)

## 5. 验证
- `xcodegen generate` → `xcodebuild -project WeChatExporterMonitor.xcodeproj -scheme WeChatExporterMonitor -destination 'generic/platform=iOS Simulator' build` 必须 ** BUILD SUCCEEDED **
- 模拟器运行: `xcrun simctl boot "iPhone 16"` → `simctl install` + `simctl launch` → 截图检查 UI
- 若本机 Xcode 27 beta 需 `sudo xcode-select -s /Applications/Xcode-beta.app`

## 6. 注意事项
- 不改动仓库其他任何文件(只新增 ios/WeChatExporterMonitor/)
- 所有网络请求带 x-diag-token 头
- 错误处理: 服务器不可达显示 "无法连接服务器" + 重试按钮
- 详情页显示 error_full 和 logs_tail(等宽字体,可滚动)
