# aws-workspace

AWS 環境で使用する自動化スクリプトやサーバーレス用ソースコード

## プロジェクト一覧

### `functions/` Serverless apps

| プロジェクト                                          | 概要                                |
| ----------------------------------------------------- | ----------------------------------- |
| [aws-cost](./functions/aws-cost/)                     | AWS 当月利用料金を Discord へ通知   |
| [discord-notify](./functions/discord-notify/)         | SNS → Discord Webhook 通知          |
| [Lambdiko（らむじこ）](./functions/lambdiko/)         | IPサイマルラジオ ダウンロードツール |
| [nhk-program-notify](./functions/nhk-program-notify/) | NHK 番組情報を Discord へ通知       |
| [podcast-download](./functions/podcast-download/)     | ポッドキャストを S3 へ保存          |

### Serverless apps (Legacy)

| プロジェクト                                              | 概要                                     |
| --------------------------------------------------------- | ---------------------------------------- |
| [lambda-discord-aws-notify](./lambda-discord-aws-notify/) | CloudWatch Logs / SNS → Discord 通知     |
| [lambda-line-notify](./lambda-line-notify/)               | CloudWatch Logs / SNS → LINE Notify 通知 |

### Infrastructure

| プロジェクト                            | 概要                 |
| --------------------------------------- | -------------------- |
| [cdk-vpc-dev-ipv6](./cdk-vpc-dev-ipv6/) | IPv6 対応 開発用 VPC |

## 開発環境構築

### AWS ツール

- [AWS CLI](https://docs.aws.amazon.com/ja_jp/cli/latest/userguide/getting-started-install.html)
- [AWS SAM CLI](https://docs.aws.amazon.com/ja_jp/serverless-application-model/latest/developerguide/install-sam-cli.html)
- [AWS CDK](https://docs.aws.amazon.com/ja_jp/cdk/v2/guide/getting_started.html)

### Prettier

```bash
# 本体・プラグイン
npm install

# Ruby プラグイン用 gem
gem install bundler prettier_print syntax_tree syntax_tree-haml syntax_tree-rbs
```
