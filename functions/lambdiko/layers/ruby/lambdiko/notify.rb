# SNS 通知
# aws-sdk-sns は各関数の Gemfile で導入する
require 'aws-sdk-sns'
require 'json'
require 'time'

def sns_publish(message)
  sns = Aws::SNS::Client.new
  sns.publish(topic_arn: ENV['SNS_TOPIC_ARN'], message: message.to_json)
end

# ダウンロード関数用通知
# status: :ok / :error
def send_download_notify(status:, description:, fields: nil)
  title = { ok: 'ダウンロード完了', error: 'ダウンロードエラー' }[status]

  message = {
    service: 'Lambdiko',
    title: title,
    status: status.to_s.upcase,
    description: description,
    fields: fields,
    timestamp: Time.now
  }
  sns_publish(message)
end

# 番組検索関数用通知
# status: :info / :warn / :error / nil（検索テスト）
def send_search_notify(status: nil, description:)
  title =
    case status
    when :info
      'リクエスト成功'
    when :warn
      '検索結果なし'
    when :error
      'リクエストエラー'
    else
      '検索テスト'
    end

  message = {
    service: 'Lambdiko',
    title: title,
    status: status.to_s.upcase,
    description: description,
    timestamp: Time.now
  }
  sns_publish(message)
end
