#!/usr/bin/env bash
# SAM スタックをデプロイし、スタックの出力から config.js を生成して静的ファイルを配置する
#   使い方: scripts/deploy.sh [--skip-sam] [sam deploy の追加オプション...]
#   環境変数: AWS_PROFILE（未指定なら AWS CLI の既定の認証情報）, AWS_REGION（既定 ap-northeast-1）, STACK_NAME（既定 lambdiko-web-player）
set -euo pipefail

cd "$(dirname "$0")/.."
export AWS_REGION="${AWS_REGION:-ap-northeast-1}"
STACK_NAME="${STACK_NAME:-lambdiko-web-player}"

if [[ "${1:-}" == "--skip-sam" ]]; then
  shift
else
  sam build
  sam deploy --stack-name "$STACK_NAME" "$@"
fi

output() {
  aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text
}

API_URL="$(output ApiUrl)"
COGNITO_DOMAIN="$(output CognitoDomain)"
CLIENT_ID="$(output UserPoolClientId)"
SITE_BUCKET="$(output SiteBucketName)"
DISTRIBUTION_ID="$(output DistributionId)"
WEB_URL="$(output WebUrl)"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp web/*.html web/*.css web/*.js "$STAGE/"
rm -f "$STAGE/config.example.js"
cat > "$STAGE/config.js" <<EOF
export default {
  apiUrl: '${API_URL}',
  cognitoDomain: '${COGNITO_DOMAIN}',
  clientId: '${CLIENT_ID}',
};
EOF

aws s3 sync "$STAGE/" "s3://${SITE_BUCKET}/" --delete --cache-control 'no-cache'
aws cloudfront create-invalidation --distribution-id "$DISTRIBUTION_ID" --paths '/*' \
  --query 'Invalidation.Id' --output text

echo "デプロイ完了: ${WEB_URL}"
