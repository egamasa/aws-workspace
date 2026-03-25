#!/usr/bin/env pwsh
#
# S3 同期スクリプト
#
# S3バケットのオブジェクトをカレントディレクトリに同期する。
#
# Usage: ./s3-sync.ps1
#
# 同期対象バケット:
#   radiko-download
#   podcast-dl
#

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function info($msg)  { Write-Host "▶ $msg" -ForegroundColor Cyan }
function ok($msg)    { Write-Host "✔ $msg" -ForegroundColor Green }
function warn($msg)  { Write-Host "⚠ $msg" -ForegroundColor Yellow }
function err($msg)   { Write-Host "✖ $msg" -ForegroundColor Red }

$Buckets = @("radiko-download", "podcast-dl")

# SSOログインチェック
info "SSOログイン確認中..."
try {
    aws sts get-caller-identity 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Not logged in" }
    ok "SSOログイン済み"
}
catch {
    warn "SSOセッションが無効です。ログインします..."
    aws sso login
    if ($LASTEXITCODE -ne 0) {
        err "SSOログイン失敗"
        exit 1
    }
    ok "SSOログイン成功"
}

# S3 同期
foreach ($bucket in $Buckets) {
    Write-Host ""
    info "s3://$bucket/ 同期中..."
    aws s3 sync "s3://$bucket/" .
    if ($LASTEXITCODE -ne 0) {
        err "$bucket 同期に失敗しました"
        exit 1
    }
}

Write-Host ""
ok "すべての同期が完了しました"
