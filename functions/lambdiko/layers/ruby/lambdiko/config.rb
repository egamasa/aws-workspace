# 共通設定値

module Lambdiko
  module Config
    # ダウンロードリトライ回数
    RETRY_LIMIT = 3
    # セグメント並列ダウンロード数
    THREAD_LIMIT = 3

    USER_AGENT =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/139.0.7258.67 Safari/537.36'

    HIBIKI_API_HEADERS = {
      'Referer' => 'http://hibiki-radio.jp/',
      'X-Requested-With' => 'XMLHttpRequest',
      'Origin' => 'http://hibiki-radio.jp',
      'User-Agent' => USER_AGENT
    }.freeze
  end
end
