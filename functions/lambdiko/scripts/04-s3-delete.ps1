#!/usr/bin/env pwsh
#
# S3 削除スクリプト
#
# S3 バケットのオブジェクトを一括削除する。
#
# Usage: ./04-s3-delete.ps1
#

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function info($msg) { Write-Host "▶ $msg" -ForegroundColor Cyan }
function ok($msg)   { Write-Host "✔ $msg" -ForegroundColor Green }
function warn($msg) { Write-Host "⚠ $msg" -ForegroundColor Yellow }
function err($msg)  { Write-Host "✖ $msg" -ForegroundColor Red }

# 設定
$Buckets = @("your-radiko-bucket-name", "your-podcast-bucket-name")

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

# 削除実行
foreach ($bucket in $Buckets) {
    Write-Host ""
    info "s3://$bucket/ オブジェクト確認中..."
    $objects = aws s3 ls "s3://$bucket" --recursive
    if (-not $objects) {
        ok "オブジェクト 0 件"
        continue
    }
    $count = ($objects | Measure-Object).Count
    $objects | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
    info "オブジェクト $count 件"

    Write-Host ""
    Write-Host "本当に削除しますか？ (y/N): " -ForegroundColor Red -NoNewline
    $confirmation = Read-Host
    if ($confirmation -ne "y") {
        warn "キャンセルしました"
        exit 0
    }

    Write-Host ""
    info "s3://$bucket/ 削除中..."
    aws s3 rm "s3://$bucket" --recursive
    if ($LASTEXITCODE -ne 0) {
        err "$bucket の削除に失敗しました"
        exit 1
    }
}

Write-Host ""
ok "すべての削除が完了しました"
