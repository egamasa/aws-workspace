# Lambdiko Web Player

[Lambdiko](../lambdiko/) で S3 に保存した録音ファイルを、ブラウザから再生する個人用 Web プレイヤー

## 構成

```text
ブラウザ
  ├─ ① ログイン（認可コード + PKCE、MFA 必須）→ Cognito マネージドログイン
  ├─ ② 画面の取得 → CloudFront →(OAC)→ S3（静的ファイル、非公開）
  ├─ ③ 一覧・再生 URL の取得（Bearer トークン）
  │     → API Gateway HTTP API（JWT オーソライザー）→ Lambda（Node.js 24 / arm64）
  │         GET /episodes          録音ファイル一覧
  │         GET /episodes/url?key= 署名付き URL を発行
  └─ ④ 再生 <audio src="署名付き URL"> → S3 録音バケット（既存、非公開）
```

- Lambda のロールは録音バケットへの `s3:ListBucket` と `s3:GetObject` のみ。
  署名付き URL も同じ権限に制限され、URL ごとに 1 ファイルしか読めない。
- 署名付き URL の有効期限は既定 3 時間（`UrlExpiresIn`）。
  期限切れなどで読み込みに失敗すると、プレイヤーが URL を取り直して同じ位置から再開する。
- Lambdiko は Content-Type を付けずに保存しているため、署名付き URL に `response-content-type=audio/mp4` を付けて iOS Safari でも再生できるようにしている。
- CloudFront で CSP・HSTS などのセキュリティヘッダーを付ける。
- フロントエンドはビルド不要の HTML / CSS / JavaScript（ES Modules）で、外部ライブラリは使っていない。

### 機能

- 録音一覧（放送日時の新しい順・古い順を切り替え、設定を保存）、タイトル・局での絞り込み、聴き終えたものの非表示
- 再生位置の保存と続きからの再生（`localStorage`、端末ごと）
- 前回再生していた番組を開いた時点で準備
- 15 秒戻し・30 秒送り、再生速度（0.75〜2 倍、設定を保存）
- ロック画面・イヤホンからの操作（Media Session API）。次・前のトラック操作で一覧の隣の番組に移る。
  iOS は秒送りを登録すると次・前のボタンを出さないため、iOS のロック画面には次・前のボタンが出ない

一覧に出るのは録音バケットに残っているファイルのみ。

ファイル名が `{タイトル}_{局ID}_{YYYYMMDDHHMM}.m4a` の形式であれば、タイトル・局・放送日時に分けて表示する。

## 費用

個人 1 人の利用であれば、ほぼ無料枠に収まる。

| サービス             | 無料枠                                                                                    |
| -------------------- | ----------------------------------------------------------------------------------------- |
| Cognito (Essentials) | 10,000 MAU まで無料                                                                       |
| CloudFront           | 毎月 1TB・1,000 万リクエストまで無料                                                      |
| Lambda               | 毎月 100 万リクエストまで無料                                                             |
| API Gateway HTTP API | 12 か月間は毎月 100 万リクエストまで無料。以降は従量課金（月数千リクエストなら 1 円未満） |
| S3 データ転送        | AWS 全体で毎月 100GB まで無料（48kbps の AAC で 4,000 時間以上）                          |

## デプロイ

### 前提

- AWS CLI、AWS SAM CLI、Node.js（`sam build` で npm を使う）
- 録音バケットと同じリージョンにデプロイすること（CSP と署名付き URL のホスト名がリージョンに依存するため）

### 設定

`samconfig.toml`（`.gitignore` 対象）で、スタック名・プロファイル・パラメータを設定する。

| パラメータ            | 説明                                                               |
| --------------------- | ------------------------------------------------------------------ |
| `AudioBucketName`     | 録音ファイルの S3 バケット名（必須）                               |
| `CognitoDomainPrefix` | ログイン画面のドメインプレフィックス。リージョン内で一意な値にする |
| `UrlExpiresIn`        | 署名付き URL の有効期限（秒、既定 10800）                          |
| `LogRetentionInDays`  | Lambda ログの保持日数（既定 30）                                   |

### 実行

`scripts/deploy.sh` が `sam build` と `sam deploy` を実行し、続けてスタックの出力から `config.js` を生成して静的ファイルを S3 に配置し、CloudFront のキャッシュを削除する。

```bash
scripts/deploy.sh
AWS_PROFILE=admin scripts/deploy.sh   # プロファイルを指定する場合

# 静的ファイルだけを更新する場合
scripts/deploy.sh --skip-sam
```

プロファイル・リージョン・スタック名は環境変数 `AWS_PROFILE`（未指定なら AWS CLI の既定の認証情報）、`AWS_REGION`（既定 `ap-northeast-1`）、`STACK_NAME`（既定 `lambdiko-web-player`）で変更できる。

### ユーザー作成

セルフサインアップは無効にしているため、ログインユーザーは管理者が作成する。

```bash
scripts/create-user.sh you@example.com
```

仮パスワードがメールで届く。
デプロイ時に表示される `WebUrl`（`https://xxxx.cloudfront.net/`）を開いてログインすると、パスワードの変更と認証アプリ（TOTP）の登録を求められる。
`WebUrl` はブラウザのブックマークやスマートフォンのホーム画面に追加しておく。

### 削除

```bash
aws s3 rm "s3://$(aws cloudformation describe-stacks --stack-name lambdiko-web-player \
  --query "Stacks[0].Outputs[?OutputKey=='SiteBucketName'].OutputValue" --output text)" --recursive
sam delete --stack-name lambdiko-web-player
```

静的ファイル用バケットを空にしてからスタックを削除する。録音バケットには影響しない。

## セキュリティ上の注意

- トークン（リフレッシュトークンを含む）はブラウザの `localStorage` に保存する。
  共用の PC では使い終わったらログアウトすること（ログアウト時にリフレッシュトークンを失効させる）。
- 署名付き URL は、有効期限内であれば URL を知っている人なら誰でも再生できる。URL を共有しないこと。
- ログイン状態は最長 30 日（リフレッシュトークンの有効期限）続く。

## テスト

```bash
(cd api && npm install)
npm test
```

| ファイル                   | 対象                                                         |
| -------------------------- | ------------------------------------------------------------ |
| `tests/api.test.mjs`       | キーの解析、一覧の並び順、ページング、署名付き URL、入力検証 |
| `tests/positions.test.mjs` | 再生位置の保存、聴了判定、古い位置情報の削除                 |

## ディレクトリ構成

```text
api/                Lambda（Node.js）
  app.mjs           ハンドラー
  lib/episodes.mjs  ファイル名の解析・一覧の整形
web/                静的ファイル（ビルド不要）
  index.html
  app.js            画面・再生
  auth.js           Cognito ログイン（PKCE）
  positions.js      再生位置の保存
  config.example.js config.js の例（config.js はデプロイ時に生成）
scripts/
  deploy.sh         デプロイ
  create-user.sh    ユーザー作成
tests/              node:test によるテスト
template.yaml       SAM テンプレート
```
