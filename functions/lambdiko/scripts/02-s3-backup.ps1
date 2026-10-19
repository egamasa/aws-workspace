#!/usr/bin/env pwsh
#
# S3 バックアップスクリプト
#
# ローカルフォルダのファイルを Amazon S3 または Cloudflare R2 にアップロードする。
#
# Usage: ./02-s3-backup.ps1
#

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

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
    err "設定ファイル lambdiko.config.psd1 が見つかりません (lambdiko.config.psd1.example を参照)"
    exit 1
}
$Config = Import-PowerShellDataFile $ConfigPath
if (-not $Config.BackupBucket) {
    err "設定ファイルに BackupBucket がありません"
    exit 1
}

# 設定（Cloudflare R2 / Amazon S3 の切り替えは設定ファイルを参照）
$Bucket   = $Config.BackupBucket
$Profile  = $Config.BackupProfile
$Endpoint = $Config.BackupEndpoint
$Year     = Split-Path $PSScriptRoot -Leaf
$Src      = $PSScriptRoot
$Dst      = "s3://$Bucket/$Year/"

$AwsArgs = @("s3", "sync", $Src, $Dst, "--exclude", "*.ps1", "--exclude", "*.psd1")
if ($Endpoint) { $AwsArgs += @("--endpoint-url", $Endpoint, "--profile", $Profile) }

# SSO ログイン確認（Amazon S3 のみ）
if (-not $Endpoint) {
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
    Write-Host ""
}

# アップロード実行
info "$Src → $Dst アップロード中..."
aws @AwsArgs
if ($LASTEXITCODE -ne 0) {
    err "アップロードに失敗しました"
    exit 1
}

Write-Host ""
ok "アップロードが完了しました"
