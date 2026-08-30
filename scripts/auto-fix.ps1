# WeChatExporter 服务器端自动修复闭环 (Windows Server 2025 计划任务入口)
# 部署: C:\WeChatExporterDiag\auto-fix.ps1
# 计划任务: 每 5 分钟运行一次
# 流程:
#   1. 扫描 C:\WeChatExporterDiag\inbox\*.json (未处理的诊断日志)
#   2. 有新日志 → 调用服务器 Hermes agent 分析并修复仓库 → 编译验证 → 版本号同步 → push tag
#   3. 处理成功的日志移动到 C:\WeChatExporterDiag\processed\ (处理失败移到 failed\)
$ErrorActionPreference = 'Continue'

$Inbox   = 'C:\WeChatExporterDiag\inbox'
$ProcDir = 'C:\WeChatExporterDiag\processed'
$FailDir = 'C:\WeChatExporterDiag\failed'
$Repo    = 'C:\WeChatExporter'
$MarkFile = 'C:\WeChatExporterDiag\.last-fix-timestamp'
$LogFile = 'C:\WeChatExporterDiag\auto-fix.log'

foreach ($d in @($Inbox, $ProcDir, $FailDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

function Write-Log($msg) {
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $msg"
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
    Write-Output $line
}

# 收集新的诊断日志(按时间排序)
$newFiles = @(Get-ChildItem -Path $Inbox -Filter '*.json' -File | Sort-Object LastWriteTime)
if ($newFiles.Count -eq 0) {
    exit 0  # 无新日志,静默退出
}
Write-Log "发现 $($newFiles.Count) 个新诊断日志: $($newFiles.Name -join ', ')"

# 逐条处理(聚合错误信息给 Hermes)
$allReports = @()
foreach ($f in $newFiles) {
    try {
        $j = Get-Content -Path $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        $allReports += "[$($f.Name)] platform=$($j.platform) version=$($j.version) stage=$($j.stage)`n错误: $($j.error)`n日志尾部:`n$($j.logs)"
    } catch {
        Write-Log "解析失败 $($f.Name): $($_.Exception.Message)"
        Move-Item $f.FullName (Join-Path $FailDir $f.Name) -Force
    }
}

# 去重:相同 stage+error 的合并(避免重复修复同一 bug)
$dedupKey = ($allReports | ForEach-Object { ($_ -split "`n")[0] }) -join ' | '
$lastKey = ''
if (Test-Path $MarkFile) { $lastKey = Get-Content $MarkFile -Raw -Encoding UTF8 }
if ($lastKey -eq $dedupKey) {
    Write-Log "与上次相同的错误已处理过,跳过"
    exit 0
}

$reportBody = $allReports -join "`n`n=====`n`n"
Set-Content -Path $MarkFile -Value $dedupKey -Encoding UTF8

Write-Log "调用 Hermes agent 修复…"

# 调用服务器 Hermes(Windows 原生安装, venv 内 hermes.exe)
$hermes = 'C:\Users\Administrator\.hermes-agent-venv\Scripts\hermes.exe'
if (-not (Test-Path $hermes)) {
    # 尝试 python -m hermes_cli
    $py = 'C:\Users\Administrator\.hermes-agent-venv\Scripts\python.exe'
    if (Test-Path $py) {
        $hermes = $py
        $hermesArgs = @('-m', 'hermes_cli')
    } else {
        $hermes = $null
    }
}
if (-not $hermes) {
    Write-Log "未找到 hermes,跳过自动修复"
    exit 1
}

$prompt = @"
你是 WeChatExporter 的自动修复 agent。服务器收到以下用户诊断日志,请分析根因并修复 GitHub 仓库 93857536-pixel/WeChatExporter 中的 bug。

诊断日志:
$reportBody

流程要求:
1. 进入 C:\WeChatExporter 仓库,先看 AGENTS.md 了解发布约定
2. 分析日志中的错误,定位根因(注意:错误消息可能来自闭源 wx.exe,先 grep 二进制确认消息来源再定修复方向)
3. 修复代码(Windows WPF 在 windows/,macOS 在 Sources/),遵循 wechat-exporter-development skill
4. 编译验证:Windows `dotnet build windows/WeChatExporter.Windows/WeChatExporter.Windows.csproj -c Release`(Windows 服务器可直接编译,无需 EnableWindowsTargeting);若改动 macOS 端则 `swift build --disable-sandbox -c release`
5. 按 AGENTS.md:版本号三处同步(纯修复补丁号+1)+ CHANGELOG + commit + tag + push
6. push 后验证 GitHub Actions 成功(gh run list),确认 Release 资产出现
7. 输出修复摘要:根因、改动文件、新版本号、CI 状态

若无法修复或编译失败,不要 push,如实报告失败原因。
"@

# 后台运行 Hermes 修复(可能耗时 10-30 分钟),写日志文件
$hermesLog = 'C:\WeChatExporterDiag\hermes-fix.log'
# ⚠️ Start-Process 传中文 query 必须整体加引号, 否则被 PowerShell 拆成多参数
$query = ('"' + $prompt + '"')
Start-Process -FilePath $hermes -ArgumentList @('chat', '-q', $query) `
    -RedirectStandardOutput $hermesLog -RedirectStandardError "$hermesLog.err" `
    -WindowStyle Hidden -Wait

Write-Log "Hermes 修复完成,日志: $hermesLog"

# 处理完的日志移走
foreach ($f in $newFiles) {
    if (Test-Path $f.FullName) { Move-Item $f.FullName (Join-Path $ProcDir $f.Name) -Force }
}
Write-Log "已移动 $($newFiles.Count) 个日志到 processed/"
