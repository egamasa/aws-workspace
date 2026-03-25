#!/usr/bin/env pwsh
#
# S3 削除スクリプト
#
# S3バケットのオブジェクトを一括削除する。
#
# Usage: ./s3-delete.ps1
#
# 削除対象バケット:
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

# S3 オブジェクト削除
foreach ($bucket in $Buckets) {
    Write-Host ""
    info "s3://$bucket/ オブジェクト一覧"
    $objects = aws s3 ls "s3://$bucket" --recursive
    if (-not $objects) {
        ok "オブジェクト 0 件"
        continue
    }
    $count = ($objects | Measure-Object).Count
    $objects | ForEach-Object { Write-Host $_ }
    info "オブジェクト $count 件"
    Write-Host ""
    Write-Host "本当に削除しますか？ (y/N): " -ForegroundColor Red -NoNewline
    $confirmation = Read-Host
    if ($confirmation -ne "y") {
        ok "キャンセルしました"
        exit 0
    }

    info "s3://$bucket/ オブジェクト削除中..."
    aws s3 rm "s3://$bucket" --recursive
    if ($LASTEXITCODE -ne 0) {
        err "$bucket オブジェクト削除に失敗しました"
        exit 1
    }
}

Write-Host ""
ok "すべてのオブジェクト削除が完了しました"
