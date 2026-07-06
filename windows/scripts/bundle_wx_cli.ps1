# 下载 jackwener/wx-cli Windows 二进制到指定目录
param(
    [Parameter(Mandatory = $true)]
    [string]$DestDir,
    [string]$WxCliVersion = "v0.3.0"
)

$ErrorActionPreference = "Stop"
$DestBin = Join-Path $DestDir "wx.exe"

if (Test-Path $DestBin) {
    Write-Host "wx.exe 已存在：$DestBin"
    exit 0
}

$Asset = "wx-windows-x86_64.exe"
$Url = "https://github.com/jackwener/wx-cli/releases/download/$WxCliVersion/$Asset"
$Tmp = Join-Path $env:TEMP "wx-cli-$WxCliVersion.exe"

Write-Host "下载内置 wx-cli $WxCliVersion …"
Invoke-WebRequest -Uri $Url -OutFile $Tmp -UseBasicParsing

New-Item -ItemType Directory -Force -Path $DestDir | Out-Null
Copy-Item $Tmp $DestBin -Force
Remove-Item $Tmp -Force -ErrorAction SilentlyContinue

Write-Host "已写入：$DestBin"
