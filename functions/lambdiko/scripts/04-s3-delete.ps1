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

# AWS CLI 出力はグレー色表示
# オブジェクト件数（download: / upload: / delete: の行数）を $script:AwsCount に格納
function Invoke-Aws {
    $script:AwsCount = 0
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & aws @args 2>&1 | ForEach-Object {
        if ("$_" -match '^(download|upload|delete): ') { $script:AwsCount++ }
        Write-Host "  $_" -ForegroundColor DarkGray
    }
    $ErrorActionPreference = $prev
}

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
if (-not $Config.SourceBuckets) {
    err "設定ファイルに SourceBuckets がありません"
    exit 1
}

# 設定
$Buckets = $Config.SourceBuckets

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
    if ($LASTEXITCODE -ne 0) {
        err "$bucket のオブジェクト一覧取得に失敗しました"
        exit 1
    }
    if (-not $objects) {
        ok "${bucket}（0 件）"
        continue
    }
    $count = ($objects | Measure-Object).Count
    $objects | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
    info "${bucket}（$count 件）"

    Write-Host ""
    Write-Host "本当に削除しますか？ (y/N): " -ForegroundColor Red -NoNewline
    $confirmation = Read-Host
    if ($confirmation -ne "y") {
        warn "キャンセルしました"
        exit 0
    }

    Write-Host ""
    info "s3://$bucket/ 削除中..."
    Invoke-Aws s3 rm "s3://$bucket" --recursive
    if ($LASTEXITCODE -ne 0) {
        err "$bucket の削除に失敗しました"
        exit 1
    }
}

Write-Host ""
ok "削除完了"
