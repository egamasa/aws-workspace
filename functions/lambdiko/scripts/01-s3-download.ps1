#!/usr/bin/env pwsh
#
# S3 ダウンロードスクリプト
#
# S3 バケットのオブジェクトをカレントディレクトリにダウンロード（同期）する。
#
# Usage: ./01-s3-download.ps1
#

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function info($msg) { Write-Host "▶ $msg" -ForegroundColor Cyan }
function ok($msg)   { Write-Host "✔ $msg" -ForegroundColor Green }
function warn($msg) { Write-Host "⚠ $msg" -ForegroundColor Yellow }
function err($msg)  { Write-Host "✖ $msg" -ForegroundColor Red }

# 設定
$Buckets = @("your-radiko-bucket-name", "your-podcast-bucket-name")
$Dst     = (Get-Location).Path

# SSO ログイン確認
info "SSO ログイン確認中..."
try {
    aws sts get-caller-identity 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Not logged in" }
    ok "SSO ログイン済み"
}
catch {
    warn "SSO セッションが無効です。ログインします..."
    aws sso login
    if ($LASTEXITCODE -ne 0) {
        err "SSO ログイン失敗"
        exit 1
    }
    ok "SSO ログイン成功"
}

# ダウンロード実行
foreach ($bucket in $Buckets) {
    Write-Host ""
    info "s3://$bucket/ → $Dst ダウンロード中..."
    aws s3 sync "s3://$bucket/" $Dst
    if ($LASTEXITCODE -ne 0) {
        err "$bucket のダウンロードに失敗しました"
        exit 1
    }
}

Write-Host ""
ok "すべてのダウンロードが完了しました"
