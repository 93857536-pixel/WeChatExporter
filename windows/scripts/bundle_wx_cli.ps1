# 将仓库内置的 vendor/windows/wx.exe 复制到目标目录
param(
    [Parameter(Mandatory = $true)]
    [string]$DestDir,
    [string]$WxCliVersion = "vendor"
)

$ErrorActionPreference = "Stop"
$Root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$VendorBin = Join-Path $Root "vendor\windows\wx.exe"
$DestBin = Join-Path $DestDir "wx.exe"

New-Item -ItemType Directory -Force -Path $DestDir | Out-Null

if ($env:LOCAL_WX_CLI -and (Test-Path $env:LOCAL_WX_CLI)) {
    Copy-Item $env:LOCAL_WX_CLI $DestBin -Force
    Write-Host "已写入本地 wx.exe：$DestBin （来自 $($env:LOCAL_WX_CLI)）"
    exit 0
}

if (-not (Test-Path $VendorBin)) {
    Write-Error "未找到 vendor/windows/wx.exe。请确认仓库包含该文件，或设置 LOCAL_WX_CLI。"
    exit 1
}

Copy-Item $VendorBin $DestBin -Force
Write-Host "已写入内置 wx.exe：$DestBin （来自 vendor/windows/wx.exe）"
