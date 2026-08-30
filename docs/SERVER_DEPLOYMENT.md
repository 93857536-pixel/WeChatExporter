# WeChatExporter 服务器端部署清单 (阿里云 ECS Windows Server 2025)

> 目标: 112.126.79.9, Administrator 免密 SSH 已配置
> 原则: 全部新增隔离部署, 不动现有 nginx/Node(3000)/CF Tunnel

## 1. 目录规划 (全部新增)
```
C:\WeChatExporterDiag\          # 诊断日志根目录
  ├── diag-server.js            # 日志接收服务 (node, 监听 8082)
  ├── inbox\                    # 新日志落盘目录
  ├── processed\                # 已处理日志
  ├── failed\                   # 解析失败日志
  ├── auto-fix.log              # 自动修复闭环日志
  ├── hermes-fix.log            # Hermes 修复输出
  └── .last-fix-timestamp       # 去重标记
C:\WeChatExporter\              # 仓库克隆 (供 Hermes 修复)
```

## 2. 部署步骤 (SSH 恢复后执行)

### 2.1 基础检查
```powershell
node --version          # 应有 Node(现有服务在用)
git --version
dotnet --version        # 需要 .NET 8 SDK (编译 WPF)
```

### 2.2 部署日志接收服务
```powershell
# 建目录
New-Item -ItemType Directory -Path C:\WeChatExporterDiag\inbox,C:\WeChatExporterDiag\processed,C:\WeChatExporterDiag\failed -Force
# 上传 scripts/diag-server.js 到 C:\WeChatExporterDiag\diag-server.js
# 测试启动
node C:\WeChatExporterDiag\diag-server.js
# 本机自测
curl -X POST http://127.0.0.1:8082/v1/diag -H "x-diag-token: wxexporter-diag-2026" -d '{"app":"t","platform":"t","stage":"t","error":"t"}'
# 注册计划任务开机自启 + 看门狗(每5分钟检查,挂了拉起)
schtasks /Create /TN "WeChatExporterDiagServer" /SC ONSTART /RL HIGHEST /TR "node C:\WeChatExporterDiag\diag-server.js"
schtasks /Create /TN "WeChatExporterDiagWatchdog" /SC MINUTE /MO 5 /TR "powershell -Command \"if(-not (Get-Process node -ErrorAction SilentlyContinue | Where-Object {$_.Path -like '*node*'})){Start-Process node -ArgumentList 'C:\WeChatExporterDiag\diag-server.js' -WindowStyle Hidden}\""
# 防火墙放行 8082
New-NetFirewallRule -DisplayName "WeChatExporter Diag" -Direction Inbound -Protocol TCP -LocalPort 8082 -Action Allow
```

### 2.3 安装 Hermes agent (Windows 原生)【2026-08-30 实测可行】
```powershell
# 1) 下载 uv (本机下载再 scp, 服务器 GitHub 直连慢): https://github.com/astral-sh/uv/releases/latest/download/uv-x86_64-pc-windows-msvc.zip
#    scp uv.zip → C:\tools\uv.zip; Expand-Archive → C:\tools\uv\uv.exe
# 2) 克隆/解压 Hermes 源码 (同样本机下载 zip 再 scp): hermes-agent-main.zip → C:\hermes-agent-main
# 3) 创建 venv
& 'C:\tools\uv\uv.exe' venv C:\Users\Administrator\.hermes-agent-venv
# 4) ⚠️ 安装必须用 cmd.exe 包装! PowerShell 5.1 把 uv 的 stderr 当 NativeCommandError 中止
#    (uv pip install 的 "Using Python..." 输出走 stderr 触发 RemoteException)
cmd /c ""C:\tools\uv\uv.exe" pip install --python "C:\Users\Administrator\.hermes-agent-venv\Scripts\python.exe" -e . > C:\tools\hermes-install4.log 2>&1"
# 5) 验证
& 'C:\Users\Administrator\.hermes-agent-venv\Scripts\hermes.exe' --version   # Hermes Agent v0.20.x
# 6) 配置: C:\Users\Administrator\.hermes\config.yaml (model.deepseek + auxiliary.vision zai)
#    .env: DEEPSEEK_API_KEY / GLM_API_KEY (scp 一次, 用完删)
#    ⚠️ 首次启动会 pip install edge-tts(TTS) 卡住 → config.yaml 加:
#       tts:\n  provider: off\n  enabled: false
#    ⚠️ Start-Process 传中文参数要整体加引号, 否则被 PowerShell 拆成多参数
# 7) 复制 skill: scp -r ~/.hermes/skills/software-development/wechat-exporter-development → 服务器同路径
```

### 2.4 部署自动修复闭环
```powershell
# 上传 scripts/auto-fix.ps1 到 C:\WeChatExporterDiag\auto-fix.ps1
# 克隆仓库
git clone https://github.com/93857536-pixel/WeChatExporter C:\WeChatExporter
# 注册计划任务: 每5分钟扫描
schtasks /Create /TN "WeChatExporterAutoFix" /SC MINUTE /MO 5 /RL HIGHEST /TR "powershell -ExecutionPolicy Bypass -File C:\WeChatExporterDiag\auto-fix.ps1"
```

## 3. 客户端上传端点
- URL: https://linminhao.top/diag/v1/diag（CF Tunnel ingress: /diag/* → http://127.0.0.1:8082）
- ⚠️ 阿里云云盾拦截非 80/443 端口公网 HTTP,直连 112.126.79.9:8082 不可用
- Header: x-diag-token: wxexporter-diag-2026
- Body: {app, platform, version, build, os, timestamp, stage, error, logs}
- 客户端契约: docs/DIAGNOSTIC_UPLOAD_CONTRACT.md
- diag-server 持久化: 计划任务 WeChatExporterDiagServer(ONSTART) + WeChatExporterDiagWatchdog(每2分钟检查8082,挂了 WMI 拉起)

## 3.5 服务器监控 API (iOS App 数据源, 2026-08-30 上线)
- monitor-api.js → 127.0.0.1:8083, CF Tunnel ingress: /api/* → 8083
- 端点: GET /api/status /api/logs?limit= /api/logs/:id /api/hermes(均需 x-diag-token 头)
- 数据来源: C:\WeChatExporterDiag\inbox\processed\failed + auto-fix.log/hermes-fix.log + PowerShell 系统状态
- 持久化: 计划任务 WeChatExporterMonitorApi(ONSTART) + 看门狗 watchdog.ps1 已覆盖 8083
- iOS App 契约: docs/IOS_MONITOR_CONTRACT.md

## 4. 验证闭环
1. 手动放一个假日志到 inbox → 等 5 分钟 → 看 auto-fix.log 是否触发 Hermes
2. Hermes 修复后 push tag → GitHub Actions 自动发布
