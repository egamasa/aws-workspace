#!/usr/bin/env pwsh
#
# NAS バックアップスクリプト
#
# ローカルフォルダのファイルを NAS にミラーリングする。
#
# Usage: ./03-nas-backup.ps1
#

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::GetEncoding(932)
$OutputEncoding = [System.Text.Encoding]::GetEncoding(932)

function info($msg) { Write-Host "▶ $msg" -ForegroundColor Cyan }
function ok($msg)   { Write-Host "✔ $msg" -ForegroundColor Green }
function warn($msg) { Write-Host "⚠ $msg" -ForegroundColor Yellow }
function err($msg)  { Write-Host "✖ $msg" -ForegroundColor Red }

# 設定ファイル読み込み
$ConfigPath = @($PSScriptRoot, (Split-Path $PSScriptRoot -Parent)) |
    ForEach-Object { Join-Path $_ "lambdiko.config.psd1" } |
    Where-Object { Test-Path $_ } |
    Select-Object -First 1
if (-not $ConfigPath) {
    err "設定ファイル lambdiko.config.psd1 が見つかりません"
    exit 1
}
$Config = Import-PowerShellDataFile $ConfigPath
if (-not $Config.NasRoot) {
    err "設定ファイルに NasRoot がありません"
    exit 1
}

# 設定
$Year = Split-Path $PSScriptRoot -Leaf
$Src  = $PSScriptRoot
$Dst  = Join-Path $Config.NasRoot $Year

# NAS 接続確認
info "NAS 接続確認中..."
if (-not (Test-Path (Split-Path $Dst -Qualifier))) {
    err "NAS ドライブ '$(Split-Path $Dst -Qualifier)' にアクセスできません"
    exit 1
}
if (-not (Test-Path $Dst)) {
    New-Item -ItemType Directory -Path $Dst | Out-Null
}
ok "NAS 接続確認済み"

# バックアップ実行
Write-Host ""
info "$Src → $Dst バックアップ中..."
$copied = 0
robocopy $Src $Dst /MIR /XF "*.ps1" "*.psd1" /R:3 /W:5 /NP /NJH /NJS /NDL /NS /NC | ForEach-Object {
    $line = $_.TrimStart()
    if ($line -match '^\*EXTRA') { Write-Host "  - $($line -replace '^\*EXTRA File\s+', '')" -ForegroundColor DarkGray }
    elseif ($line -ne '')        { Write-Host "  + $line" -ForegroundColor White; $script:copied++ }
}
if ($LASTEXITCODE -ge 8) {
    err "バックアップに失敗しました (robocopy exit code: $LASTEXITCODE)"
    exit 1
}
ok "${Dst}（+ $copied 件）"

# ファイル数・フォルダ数比較
$srcFiles   = (Get-ChildItem $Src -Recurse -File -Exclude "*.ps1", "*.psd1").Count
$dstFiles   = (Get-ChildItem $Dst -Recurse -File -Exclude "*.ps1", "*.psd1").Count
$srcFolders = (Get-ChildItem $Src -Recurse -Directory).Count
$dstFolders = (Get-ChildItem $Dst -Recurse -Directory).Count
Write-Host ""
if ($srcFiles -eq $dstFiles -and $srcFolders -eq $dstFolders) {
    ok "ファイル $srcFiles 件 / フォルダ $srcFolders 件 一致"
    Write-Host ""
    ok "バックアップ完了"
}
else {
    if ($srcFiles   -ne $dstFiles)   { err "ファイル数不一致: コピー元 $srcFiles 件 / コピー先 $dstFiles 件" }
    if ($srcFolders -ne $dstFolders) { err "フォルダ数不一致: コピー元 $srcFolders 件 / コピー先 $dstFolders 件" }
    Write-Host ""
    err "バックアップ結果を確認してください"
    exit 1
}
