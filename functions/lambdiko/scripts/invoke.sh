#!/bin/bash
#
# Lambdiko 手動実行スクリプト
#
# イベントJSONファイルを指定してLambda関数を実行する。
# 呼び出すLambda関数名はイベントJSONファイル名から自動判定（判定できない場合は対話的に選択）
#
# Usage: ./invoke.sh <event.json>
#
# ファイル名パターン → 関数名:
#   program*.json  → lambdiko-program-search
#   radiko*.json   → lambdiko-radiko-download
#   radiru*.json   → lambdiko-radiru-download
#
set -euo pipefail

FUNCTIONS=("lambdiko-program-search" "lambdiko-radiko-download" "lambdiko-radiru-download")

# 色定義
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
RESET='\033[0m'

info()  { echo -e "${CYAN}▶${RESET} $1"; }
ok()    { echo -e "${GREEN}✔${RESET} $1"; }
warn()  { echo -e "${YELLOW}⚠${RESET} $1"; }
error() { echo -e "${RED}✖${RESET} $1" >&2; }

# SSOログインチェック
info "SSOログイン確認中..."
if aws sts get-caller-identity &>/dev/null; then
  ok "SSOログイン済み"
else
  warn "SSOセッションが無効です。ログインします..."
  if aws sso login; then
    ok "SSOログイン成功"
  else
    error "SSOログイン失敗"
    exit 1
  fi
fi

usage() {
  echo ""
  echo "Usage: $0 <event.json>"
  echo ""
  echo "Lambda関数名はイベントファイル名から自動判定されます。"
  echo "  program*.json  → lambdiko-program-search"
  echo "  radiko*.json   → lambdiko-radiko-download"
  echo "  radiru*.json   → lambdiko-radiru-download"
  echo ""
  echo "判定できない場合は対話的に選択します。"
  exit 1
}

select_function() {
  echo ""
  echo "Lambda関数を選択してください:"
  for i in "${!FUNCTIONS[@]}"; do
    echo "  $((i + 1))) ${FUNCTIONS[$i]}"
  done
  read -rp "> " choice
  if [[ "$choice" =~ ^[1-3]$ ]]; then
    echo "${FUNCTIONS[$((choice - 1))]}"
  else
    error "無効な選択です"
    exit 1
  fi
}

detect_function() {
  local filename
  filename=$(basename "$1")
  case "$filename" in
    program*) echo "lambdiko-program-search" ;;
    radiko*) echo "lambdiko-radiko-download" ;;
    radiru*) echo "lambdiko-radiru-download" ;;
    *) select_function ;;
  esac
}

[[ $# -lt 1 ]] && usage

EVENT_FILE="$1"
[[ ! -f "$EVENT_FILE" ]] && { error "$EVENT_FILE が見つかりません"; exit 1; }

FUNCTION_NAME=$(detect_function "$EVENT_FILE")

echo ""
info "関数:     $FUNCTION_NAME"
info "イベント: $EVENT_FILE"
echo ""

aws lambda invoke \
  --function-name "$FUNCTION_NAME" \
  --cli-binary-format raw-in-base64-out \
  --payload file://"$EVENT_FILE" \
  --no-cli-pager \
  /dev/stdout
