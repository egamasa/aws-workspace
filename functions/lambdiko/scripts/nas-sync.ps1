#!/usr/bin/env pwsh
#
# NAS バックアップスクリプト
#
# ローカルフォルダのファイルを NAS にミラーリングする。
#
# Usage: ./nas-sync.ps1
#

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::GetEncoding(932)
$OutputEncoding = [System.Text.Encoding]::GetEncoding(932)

function info($msg) { Write-Host "▶ $msg" -ForegroundColor Cyan }
function ok($msg)   { Write-Host "✔ $msg" -ForegroundColor Green }
function err($msg)  { Write-Host "✖ $msg" -ForegroundColor Red }

$Src = $PSScriptRoot
$Year = Split-Path $PSScriptRoot -Leaf
$Dst = "Z:\Radio\$Year"

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
info "$Src → $Dst 同期中..."
robocopy $Src $Dst /MIR /XF "*.ps1" /R:3 /W:5 /NP /NJH /NJS /NDL /NS /NC | ForEach-Object {
    $line = $_.TrimStart()
    if ($line -match '^\*EXTRA') { Write-Host "  - $($line -replace '^\*EXTRA File\s+',''  )" -ForegroundColor DarkGray }
    elseif ($line -ne '')        { Write-Host "  + $line" -ForegroundColor White }
}
if ($LASTEXITCODE -ge 8) {
    err "バックアップに失敗しました (robocopy exit code: $LASTEXITCODE)"
    exit 1
}

# ファイル数・フォルダ数比較
$srcFiles   = (Get-ChildItem $Src -Recurse -File      -Exclude "*.ps1").Count
$dstFiles   = (Get-ChildItem $Dst -Recurse -File                      ).Count
$srcFolders = (Get-ChildItem $Src -Recurse -Directory                 ).Count
$dstFolders = (Get-ChildItem $Dst -Recurse -Directory                 ).Count
Write-Host ""
if ($srcFiles -eq $dstFiles -and $srcFolders -eq $dstFolders) {
    ok "ファイル数一致: $srcFiles 件 / フォルダ数一致: $srcFolders 件"
} else {
    if ($srcFiles   -ne $dstFiles)   { err "ファイル数不一致: コピー元 $srcFiles 件 / コピー先 $dstFiles 件" }
    if ($srcFolders -ne $dstFolders) { err "フォルダ数不一致: コピー元 $srcFolders 件 / コピー先 $dstFolders 件" }
}

Write-Host ""
Read-Host "Enter キーで終了"
