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

# ---------------------------------------------------------------
# 設定
# ---------------------------------------------------------------
# $Bucket: アップロード先のバケット名
$Bucket = "your-bucket-name"
$Year   = Split-Path $PSScriptRoot -Leaf
$Src    = $PSScriptRoot
$Dst    = "s3://$Bucket/$Year/"

# Cloudflare R2 を使う場合:
#   1. Cloudflare ダッシュボード → R2 → Manage R2 API Tokens でトークンを発行
#   2. aws configure --profile r2 で Access Key ID / Secret Access Key を登録
#   3. $Profile にプロファイル名を設定
#   4. $Endpoint に R2 のエンドポイント URL を設定
#      （Cloudflare ダッシュボード → R2 → バケット → Settings で確認）
#
# Amazon S3 を使う場合:
#   $Endpoint を空文字にする（AWS SSO でログイン済みであること）
# ---------------------------------------------------------------
$Profile  = "r2"
$Endpoint = "https://<account_id>.r2.cloudflarestorage.com"
# $Endpoint = ""  # Amazon S3 の場合はこちらを使用
# ---------------------------------------------------------------

$AwsArgs = @("s3", "sync", $Src, $Dst, "--exclude", "*.ps1")
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
