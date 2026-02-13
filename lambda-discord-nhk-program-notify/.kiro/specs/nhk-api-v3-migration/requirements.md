# 要件定義書

## はじめに

本ドキュメントは、NHK番組通知Lambda関数を廃止予定のNHK番組表API Ver.2から新しいNHK番組表API Ver.3へ移行するための要件を定義します。Ruby 3.3で記述されたこのLambda関数は、ジャンルまたはキーワード検索に基づいてNHK番組情報を取得し、Discordチャンネルにフォーマットされた通知を送信します。移行では、APIエンドポイントの更新とv3 APIの構造変更への対応を行いながら、既存のすべての機能を維持する必要があります。

## 用語集

- **Lambda_Function**: NHK番組データを取得しDiscord通知を送信するAWS Lambda関数
- **NHK_API_v2**: 廃止予定のNHK番組表APIバージョン2
- **NHK_API_v3**: 新しいNHK番組表APIバージョン3
- **Discord_Client**: 通知送信に使用されるDiscordrb webhookクライアント
- **Program_Data**: NHK番組情報(タイトル、開始時刻、内容、サービス、地域)を含むJSONレスポンス
- **Genre_Search**: ジャンルコードでフィルタリングされた番組を取得するAPI操作
- **List_Search**: サービス/地域/日付のすべての番組を取得するAPI操作
- **Keyword_Search**: キーワードマッチングによる番組のクライアント側フィルタリング
- **Service_ID**: NHK放送サービスの識別子(g1、e1、s1など)
- **Area_ID**: 放送地域を識別する3桁のコード(東京は130など)
- **Genre_ID**: 番組ジャンルを識別する4桁のコード(ドラマは0300など)
- **BS8K_Filter**: NHK BS8K(サービスID s6)番組の除外オプション
- **Subchannel_Deduplication**: サブチャンネルで放送される重複番組の削除
- **SAM_Template**: デプロイ用のAWS Serverless Application Modelテンプレート
- **SSM_Parameter**: APIキーとwebhook URLのAWS Systems Manager Parameter Store値

## 要件

### 要件1: APIエンドポイントの移行

**ユーザーストーリー:** システム保守担当者として、v2廃止後もLambda関数が動作し続けるように、NHK API v2からv3エンドポイントへ移行したい。

#### 受入基準

1. WHEN Lambda_Functionがジャンル別に番組を取得する THEN Lambda_FunctionはNHK_API_v3のジャンル検索エンドポイントを使用すること
2. WHEN Lambda_Functionがキーワード検索用に番組を取得する THEN Lambda_FunctionはNHK_API_v3のリスト検索エンドポイントを使用すること
3. THE Lambda_FunctionはAPIリクエストURLをv3エンドポイント形式で構築すること
4. WHEN APIリクエストを行う THEN Lambda_FunctionはNHK_API_v3が要求する形式でAPIキーを含めること
5. THE Lambda_FunctionはNHK_API_v2エンドポイントURLへのすべての参照を削除すること

### 要件2: APIレスポンス形式への対応

**ユーザーストーリー:** システム保守担当者として、番組データが正しく抽出・処理されるように、v3 APIレスポンス形式の変更に対応したい。

#### 受入基準

1. WHEN Lambda_FunctionがNHK_API_v3からレスポンスを受信する THEN Lambda_Functionはv3形式に従ってJSON構造を解析すること
2. WHEN 番組情報を抽出する THEN Lambda_Functionはv3レスポンスフィールドを必要なデータフィールド(title、start_time、content、service、area)にマッピングすること
3. IF v3レスポンス構造がv2と異なる THEN Lambda_Functionはそれに応じて解析ロジックを適応させること
4. WHEN v3 APIが番組リストを返す THEN Lambda_Functionはレスポンス構造を正しく反復処理すること
5. THE Lambda_Functionはv3レスポンスで名前変更または再構造化されたフィールドを処理すること

### 要件3: コードマッピングの更新

**ユーザーストーリー:** システム保守担当者として、APIリクエストが有効な識別子を使用するように、地域・サービス・ジャンルコードマッピングがv3で正確であることを確認したい。

#### 受入基準

1. THE Lambda_Functionはconstants.rb内のすべてのArea_IDコードがNHK_API_v3で有効であることを検証すること
2. THE Lambda_Functionはconstants.rb内のすべてのService_IDコードがNHK_API_v3で有効であることを検証すること
3. THE Lambda_Functionはconstants.rb内のすべてのGenre_IDコードがNHK_API_v3で有効であることを検証すること
4. IF v3でコードが変更されている THEN Lambda_Functionはconstants.rbのマッピングを更新すること
5. IF v3でサービス名またはジャンル名が変更されている THEN Lambda_Functionはconstants.rbの表示名を更新すること

### 要件4: 機能の保持

**ユーザーストーリー:** ユーザーとして、番組通知が中断なく継続されるように、移行後もすべての既存機能が同じように動作することを望む。

#### 受入基準

1. WHEN ジャンル検索がリクエストされる THEN Lambda_Functionは移行前と同様にそのジャンルに一致する番組を返すこと
2. WHEN キーワード検索がリクエストされる THEN Lambda_Functionは指定されたフィールドにキーワードを含む番組をフィルタリングすること
3. WHEN BS8K_Filterが有効 THEN Lambda_FunctionはService_ID s6の番組を除外すること
4. WHEN 番組を処理する THEN Lambda_Functionはタイトルと開始時刻によるSubchannel_Deduplicationを実行すること
5. WHEN 番組が見つかる THEN Lambda_Functionは開始時刻の昇順でソートすること
6. WHEN Discord通知を送信する THEN Lambda_Functionは同じ構造と内容でメッセージをフォーマットすること
7. THE Lambda_Functionは同じLambdaイベントペイロード形式(days_after、area、service、genre、keyword、items)をサポートすること

### 要件5: 認証と設定

**ユーザーストーリー:** システム保守担当者として、APIリクエストが適切に認証されるように、v3で認証が機能することを確認したい。

#### 受入基準

1. THE Lambda_Functionは既存のメカニズムを使用してSSM_ParameterからAPIキーを取得すること
2. WHEN NHK_API_v3リクエストを行う THEN Lambda_Functionはv3が要求する認証形式でAPIキーを含めること
3. IF v3がv2と異なる認証方法を使用する THEN Lambda_Functionは新しい認証方法を実装すること
4. THE Lambda_FunctionはSSM_ParameterからDiscord webhook URLを取得し続けること
5. THE Lambda_FunctionはEXCLUDE_BS8K_PROGRAMS環境変数のサポートを維持すること

### 要件6: エラーハンドリングと回復性

**ユーザーストーリー:** システム保守担当者として、障害が適切にログ記録され処理されるように、v3 API相互作用のための堅牢なエラーハンドリングを望む。

#### 受入基準

1. WHEN NHK_API_v3リクエストが失敗する THEN Lambda_Functionはクラッシュせずにエラーを適切に処理すること
2. WHEN v3 APIがエラーレスポンスを返す THEN Lambda_Functionはエラー詳細をログに記録すること
3. WHEN v3 APIが予期しないレスポンス形式を返す THEN Lambda_Functionは解析エラーを処理すること
4. IF 番組が見つからない THEN Lambda_FunctionはDiscord通知を送信しないこと
5. WHEN Discord_Clientがメッセージ送信に失敗する THEN Lambda_Functionはエラーを適切に処理すること

### 要件7: デプロイとインフラストラクチャ

**ユーザーストーリー:** システム保守担当者として、既存の手順を使用して移行された関数をデプロイできるように、デプロイプロセスが変更されないことを望む。

#### 受入基準

1. THE SAM_Templateは同じ構造とパラメータを維持すること
2. THE Lambda_FunctionはRuby 3.3ランタイムを使い続けること
3. THE Lambda_FunctionはSSM_Parameterアクセスのための同じIAM権限を維持すること
4. THE Lambda_Functionは同じタイムアウトとメモリ設定を維持すること
5. THE Lambda_FunctionはAWS Parameters and Secrets Lambda Extension layerを使い続けること

### 要件8: テストと検証

**ユーザーストーリー:** システム保守担当者として、本番環境に自信を持ってデプロイできるように、移行が正しく機能することを検証したい。

#### 受入基準

1. WHEN ジャンル検索でテストする THEN Lambda_FunctionはNHK_API_v3から番組を正常に取得して表示すること
2. WHEN キーワード検索でテストする THEN Lambda_Functionは一致する番組を正常にフィルタリングして表示すること
3. WHEN 異なる地域コードでテストする THEN Lambda_Functionは正しい放送地域の番組を取得すること
4. WHEN 異なるサービスIDでテストする THEN Lambda_Functionは正しいサービスの番組を取得すること
5. WHEN BS8K_Filterをテストする THEN Lambda_Functionは設定に基づいてBS8K番組を正しく除外または含めること
6. WHEN Subchannel_Deduplicationをテストする THEN Lambda_Functionは重複番組を削除すること
7. WHEN Discord通知をテストする THEN Lambda_Functionは適切にフォーマットされたメッセージを送信すること

### 要件9: ドキュメントの更新

**ユーザーストーリー:** システム保守担当者として、将来の保守担当者が実装を理解できるように、v3移行を反映した更新されたドキュメントを望む。

#### 受入基準

1. THE Lambda_FunctionリポジトリはNHK_API_v3を参照する更新されたREADMEドキュメントを含むこと
2. WHEN APIエンドポイントを文書化する THEN ドキュメントはv3エンドポイントURLを示すこと
3. THE ドキュメントはv2からv3への重要な変更を記載すること
4. THE ドキュメントはv3固有の新しい設定または要件を含むこと
5. IF v3が異なるレート制限または制約を持つ THEN ドキュメントはこれらを文書化すること

### 要件10: 後方互換性

**ユーザーストーリー:** システム保守担当者として、既存のEventBridgeルールと呼び出しが引き続き機能するように、Lambdaイベントペイロード形式が互換性を保つことを確認したい。

#### 受入基準

1. THE Lambda_Functionは移行前と同じイベントペイロード構造を受け入れること
2. WHEN イベントにdays_after、area、service、genre、keyword、またはitemsフィールドが含まれる THEN Lambda_Functionはそれらを同じように処理すること
3. THE Lambda_Functionはareaが指定されていない場合のデフォルト値'tokyo'を維持すること
4. THE Lambda_Functionは単一の呼び出しで複数のイベントオブジェクトをサポートし続けること
5. THE Lambda_Functionは既存のEventBridgeルールまたはスケジュールされたイベントへの変更を必要としないこと
