#!/usr/bin/env bash
# ログインユーザーを作成する。仮パスワードが指定のメールアドレスに届く
#   使い方: scripts/create-user.sh you@example.com
#   環境変数: AWS_PROFILE（未指定なら AWS CLI の既定の認証情報）, AWS_REGION（既定 ap-northeast-1）, STACK_NAME（既定 lambdiko-web-player）
set -euo pipefail

EMAIL="${1:?usage: $0 <email>}"
export AWS_REGION="${AWS_REGION:-ap-northeast-1}"
STACK_NAME="${STACK_NAME:-lambdiko-web-player}"

USER_POOL_ID="$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='UserPoolId'].OutputValue" --output text)"

aws cognito-idp admin-create-user \
  --user-pool-id "$USER_POOL_ID" \
  --username "$EMAIL" \
  --user-attributes Name=email,Value="$EMAIL" Name=email_verified,Value=true \
  --desired-delivery-mediums EMAIL \
  --query 'User.{Username:Username,Status:UserStatus}' --output table

echo "仮パスワードを ${EMAIL} に送信しました。初回ログイン時にパスワード変更と認証アプリ（TOTP）の登録を求められます。"
