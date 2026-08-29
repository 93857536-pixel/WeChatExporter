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

### 2.3 安装 Hermes agent (Windows 原生)
```powershell
# 1) 安装 uv (Python 包管理器)
powershell -ExecutionPolicy ByPass -c "irm https://astral.sh/uv/install.ps1 | iex"
# 2) 克隆 Hermes
git clone https://github.com/NousResearch/hermes-agent C:\hermes-agent
# 3) 创建 venv + 安装
cd C:\hermes-agent
uv venv C:\Users\Administrator\.hermes-agent-venv
C:\Users\Administrator\.hermes-agent-venv\Scripts\activate
uv pip install -e .
# 4) 配置 (模型/密钥从本机复制: ~/.hermes/config.yaml 的 providers + .env 的 API keys)
#    注意: 服务器只保留 deepseek/zai provider, 删除本地模型
# 5) 安装 wechat-exporter-development skill
hermes skill install ... (或直接复制本机 ~/.hermes/skills/software-development/wechat-exporter-development)
# 6) gh 授权 (GitHub token, 需有 repo + push 权限)
gh auth login
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

## 4. 验证闭环
1. 手动放一个假日志到 inbox → 等 5 分钟 → 看 auto-fix.log 是否触发 Hermes
2. Hermes 修复后 push tag → GitHub Actions 自动发布
