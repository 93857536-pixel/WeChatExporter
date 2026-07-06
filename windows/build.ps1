# 构建 Windows 版 WeChatExporter（含内置 wx-cli）
param(
    [string]$WxCliVersion = "v0.3.0",
    [string]$Configuration = "Release",
    [switch]$SelfContained = $true
)

$ErrorActionPreference = "Stop"
$Root = $PSScriptRoot
$Project = Join-Path $Root "WeChatExporter.Windows"
$OutDir = Join-Path $Root "publish"
$DistDir = Join-Path $Root "dist\WeChatExporter"

$publishArgs = @(
    "publish", $Project,
    "-c", $Configuration,
    "-r", "win-x64",
    "-o", $OutDir,
    "/p:PublishSingleFile=false"
)

if ($SelfContained) {
    Write-Host "编译 Windows 应用（自包含，无需安装 .NET）…"
    $publishArgs += @("--self-contained", "true")
} else {
    Write-Host "编译 Windows 应用（需安装 .NET 8 Runtime）…"
    $publishArgs += @("--self-contained", "false")
}

dotnet @publishArgs

Write-Host "打包内置 wx-cli $WxCliVersion …"
& (Join-Path $Root "scripts\bundle_wx_cli.ps1") -DestDir $OutDir -WxCliVersion $WxCliVersion

if (Test-Path $DistDir) { Remove-Item $DistDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $DistDir | Out-Null
Copy-Item (Join-Path $OutDir "*") $DistDir -Recurse -Force

Write-Host ""
Write-Host "完成：$DistDir"
Write-Host "运行：$DistDir\WeChatExporter.exe"
