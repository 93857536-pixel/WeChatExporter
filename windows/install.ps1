# 构建并安装到桌面与开始菜单
param(
    [string]$WxCliVersion = "v0.3.0"
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot

& (Join-Path $Root "build.ps1") -WxCliVersion $WxCliVersion

$Src = Join-Path $Root "dist\WeChatExporter"
$Desktop = Join-Path ([Environment]::GetFolderPath("Desktop")) "WeChatExporter"
$Programs = Join-Path ([Environment]::GetFolderPath("StartMenu")) "Programs\WeChatExporter"

foreach ($Target in @($Desktop, $Programs)) {
    if (Test-Path $Target) { Remove-Item $Target -Recurse -Force }
    Copy-Item $Src $Target -Recurse -Force
}

Write-Host ""
Write-Host "Windows 版已安装到："
Write-Host "  $Desktop"
Write-Host "  $Programs"
Write-Host ""
Write-Host "首次使用建议右键 WeChatExporter.exe → 以管理员身份运行"
