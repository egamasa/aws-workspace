// ローカル確認用の設定例。デプロイ時は scripts/deploy.sh がスタックの出力から config.js を生成する
export default {
  apiUrl: 'https://xxxxxxxxxx.execute-api.ap-northeast-1.amazonaws.com',
  cognitoDomain: 'https://lambdiko-player-xxxxxx.auth.ap-northeast-1.amazoncognito.com',
  clientId: 'xxxxxxxxxxxxxxxxxxxxxxxxxx',
};
