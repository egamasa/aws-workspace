# NHK API v3 移行調査 - 最終結果

## 調査完了日

2026年2月12日

## ✓ v3 API確認完了

NHK API v3は存在し、正常に動作しています。

## v3エンドポイント

### ドメイン変更

- **v2**: `api.nhk.or.jp`
- **v3**: `program-api.nhk.jp`

### エンドポイント一覧

#### テレビ

```
# リスト検索
https://program-api.nhk.jp/v3/papiPgDateTv?service={service_tv}&area={area}&date={date}&key={apikey}

# ジャンル検索
https://program-api.nhk.jp/v3/papiPgGenreTv?service={service_tv}&area={area}&genre={genre}&date={date}&key={apikey}
```

#### ラジオ

```
# リスト検索
https://program-api.nhk.jp/v3/papiPgDateRadio?service={service_radio}&area={area}&date={date}&key={apikey}

# ジャンル検索
https://program-api.nhk.jp/v3/papiPgGenreRadio?service={service_radio}&area={area}&genre={genre}&date={date}&key={apikey}
```

## 主な変更点

### 1. URL構造の変更

- **v2**: RESTful パス形式 `/v2/pg/genre/{area}/{service}/{genre}/{date}.json?key={key}`
- **v3**: クエリパラメータ形式 `/v3/papiPgDateTv?service={service}&area={area}&date={date}&key={key}`

### 2. テレビとラジオの分離

v3では、テレビとラジオで別々のエンドポイントを使用:

- テレビ: `papiPgDateTv`, `papiPgGenreTv`
- ラジオ: `papiPgDateRadio`, `papiPgGenreRadio`

### 3. レスポンス構造の大幅な変更

#### v2レスポンス構造

```json
{
  "list": {
    "g1": [
      {
        "id": "2026021233005",
        "event_id": "33005",
        "start_time": "2026-02-12T04:05:00+09:00",
        "end_time": "2026-02-12T06:00:00+09:00",
        "area": {
          "id": "130",
          "name": "東京"
        },
        "service": {
          "id": "g1",
          "name": "ＮＨＫ総合１"
        },
        "title": "番組タイトル",
        "subtitle": "サブタイトル",
        "content": "番組内容",
        "act": "出演者情報",
        "genres": ["0106"]
      }
    ]
  }
}
```

#### v3レスポンス構造

```json
{
  "g1": {
    "publishedOn": [
      {
        "type": "BroadcastService",
        "id": "bs-g1-130",
        "name": "NHK総合テレビジョン",
        "broadcastDisplayName": "NHK総合・東京",
        "identifierGroup": {
          "serviceId": "g1",
          "serviceName": "NHK総合1",
          "areaId": "130",
          "areaName": "東京"
        }
      }
    ],
    "publication": [
      {
        "type": "BroadcastEvent",
        "id": "g1-130-2026021233006",
        "name": "番組タイトル",
        "description": "番組内容",
        "startDate": "2026-02-12T06:00:00+09:00",
        "endDate": "2026-02-12T06:30:00+09:00",
        "identifierGroup": {
          "broadcastEventId": "g1-130-2026021233006",
          "tvEpisodeId": "QMZL118ZJJ",
          "tvEpisodeName": "エピソード名",
          "tvSeriesId": "QLP4RZ8ZY3",
          "tvSeriesName": "シリーズ名",
          "serviceId": "g1",
          "areaId": "130",
          "eventId": "33006",
          "genre": [
            {
              "id": "0000",
              "name1": "ニュース/報道",
              "name2": "定時・総合"
            }
          ]
        },
        "misc": {
          "actList": [
            {
              "role": "キャスター",
              "name": "出演者名",
              "nameRuby": "ﾌﾘｶﾞﾅ"
            }
          ]
        }
      }
    ]
  }
}
```

## フィールドマッピング (v2 → v3)

### トップレベル構造

| v2                 | v3             | 説明                           |
| ------------------ | -------------- | ------------------------------ |
| `list`             | `{service_id}` | サービスIDがトップレベルキーに |
| `list[service_id]` | `publication`  | 番組リストの配列               |
| -                  | `publishedOn`  | サービス情報（新規）           |

### 番組オブジェクト

| v2フィールド   | v3フィールド                       | 変更内容                       |
| -------------- | ---------------------------------- | ------------------------------ |
| `id`           | `identifierGroup.broadcastEventId` | ネスト化                       |
| `event_id`     | `identifierGroup.eventId`          | ネスト化                       |
| `start_time`   | `startDate`                        | 名前変更                       |
| `end_time`     | `endDate`                          | 名前変更                       |
| `title`        | `name`                             | 名前変更                       |
| `subtitle`     | `identifierGroup.tvEpisodeName`    | ネスト化                       |
| `content`      | `description`                      | 名前変更                       |
| `act`          | `misc.actList`                     | 構造化された配列に             |
| `area.id`      | `identifierGroup.areaId`           | ネスト化                       |
| `area.name`    | `identifierGroup.areaName`         | ネスト化（publishedOnにも）    |
| `service.id`   | `identifierGroup.serviceId`        | ネスト化                       |
| `service.name` | `identifierGroup.serviceName`      | ネスト化（publishedOnにも）    |
| `genres`       | `identifierGroup.genre`            | 構造化されたオブジェクト配列に |

### ジャンル構造の変更

**v2**: 文字列配列

```json
"genres": ["0106"]
```

**v3**: オブジェクト配列

```json
"genre": [
  {
    "id": "0106",
    "name1": "スポーツ",
    "name2": "オリンピック・国際大会"
  }
]
```

### 出演者情報の変更

**v2**: 文字列

```json
"act": "【キャスター】高井正智，中山果奈"
```

**v3**: 構造化された配列

```json
"actList": [
  {
    "role": "キャスター",
    "name": "高井正智",
    "nameRuby": "ﾀｶｲﾏｻﾄﾓ"
  },
  {
    "role": "キャスター",
    "name": "中山果奈",
    "nameRuby": "ﾅｶﾔﾏｶﾅ"
  }
]
```

## 認証方法

v2とv3で同じ:

- クエリパラメータ: `?key={api_key}`
- 同じAPIキーが使用可能

## 地域・サービス・ジャンルコード

### 確認結果

- **地域コード**: v2と同じ（'130' = 東京など）
- **サービスコード**: v2と同じ（'g1', 'r1'など）
- **ジャンルコード**: v2と同じ（'0700' = アニメなど）

既存の `constants.rb` のコードマッピングはそのまま使用可能です。

## 実装への影響

### 必須の変更

1. **エンドポイントURL定数の更新**

   ```ruby
   # v2
   API_BASE_URL_GENRE = 'https://api.nhk.or.jp/v2/pg/genre/'
   API_BASE_URL_LIST = 'https://api.nhk.or.jp/v2/pg/list/'
   
   # v3
   API_BASE_URL_TV_GENRE = 'https://program-api.nhk.jp/v3/papiPgGenreTv'
   API_BASE_URL_TV_LIST = 'https://program-api.nhk.jp/v3/papiPgDateTv'
   API_BASE_URL_RADIO_GENRE = 'https://program-api.nhk.jp/v3/papiPgGenreRadio'
   API_BASE_URL_RADIO_LIST = 'https://program-api.nhk.jp/v3/papiPgDateRadio'
   ```

2. **URL構築ロジックの変更**

   ```ruby
   # v2
   url = "#{API_BASE_URL_GENRE}#{area_id}/#{service_id}/#{genre_id}/#{date}.json?key=#{@api_key}"
   
   # v3
   url =
     "#{API_BASE_URL_TV_GENRE}?service=#{service_id}&area=#{area_id}&genre=#{genre_id}&date=#{date}&key=#{@api_key}"
   ```

3. **サービスタイプの判定**
   テレビとラジオで異なるエンドポイントを使用:

   ```ruby
   def is_tv_service?(service_id)
     %w[g1 g2 e1 e2 e3 e4 s1 s2 s5 s6].include?(service_id)
   end
   
   def is_radio_service?(service_id)
     %w[r1 r2 r3 n1 n2 n3].include?(service_id)
   end
   ```

4. **レスポンスパーサーの完全な書き換え**

   - トップレベル: `list` → `{service_id}.publication`
   - フィールド名: `start_time` → `startDate`, `title` → `name` など
   - ネスト構造: `identifierGroup` からの取得
   - ジャンル: 文字列配列 → オブジェクト配列

5. **search_programsメソッドの更新**

   ```ruby
   # v2
   programs['list'].each do |service, programs|
     programs.each do |program|
       # program['start_time'], program['title'] など
     end
   end
   
   # v3
   programs[service_id]['publication'].each do |program|
     # program['startDate'], program['name'] など
     # program['identifierGroup']['genre'] など
   end
   ```

6. **send_messageメソッドの更新**

   ```ruby
   # v2
   program['title']
   program['start_time']
   program['content']
   program['service']['id']
   program['area']['name']
   
   # v3
   program['name']
   program['startDate']
   program['description']
   program['identifierGroup']['serviceId']
   program['identifierGroup']['areaName']
   # または publishedOn[0]['identifierGroup']['areaName']
   ```

### 追加機能の可能性

v3では以下の追加情報が利用可能:

- エピソードID、シリーズID
- 番組ロゴ、アイキャッチ画像のURL
- 構造化された出演者情報（役割、ふりがな付き）
- ジャンル名（日本語）
- 見逃し配信情報（`misc.hsk`）
- 番組の詳細URL

## 後方互換性

- v2 APIは現在も動作中
- 同じAPIキーでv2とv3の両方にアクセス可能
- 段階的な移行が可能

## レート制限

v2とv3で同じと思われるが、公式ドキュメントで確認が必要。

## 次のステップ

1. ✓ v3エンドポイントの確認 - 完了
2. ✓ レスポンス構造の分析 - 完了
3. → コードの実装開始
   - エンドポイントURL更新
   - サービスタイプ判定ロジック追加
   - レスポンスパーサー書き換え
   - テストの実装

## 参考ファイル

- `v2_sample_program.json` - v2の番組オブジェクト例
- `v3_response_full.json` - v3の完全なレスポンス例
- `test_nhk_api_v3_correct.rb` - v3エンドポイントテストスクリプト
