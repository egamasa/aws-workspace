unless File.exist?('/opt/ruby/lib/lambdiko')
  $LOAD_PATH.unshift(File.expand_path('../layers/ruby', __dir__))
end

require 'aws-sdk-lambda'
require 'date'
require 'json'
require 'logger'
require 'lambdiko/notify'
require_relative 'lib/hibiki_searcher'
require_relative 'lib/radiko_searcher'
require_relative 'lib/radiru_searcher'

LOGGER = Logger.new($stdout) unless defined?(LOGGER)
WDAY_LIST = { sun: 0, mon: 1, tue: 2, wed: 3, thu: 4, fri: 5, sat: 6 }.freeze

# 放送局ID別の検索クラス
# 各クラスは search / download_function_name を実装する
SEARCHERS = { radiko: RadikoSearcher, radiru: RadiruSearcher, hibiki: HibikiSearcher }.freeze

# 直近の指定曜日の日付を算出
def prev_date_of_week(week, include_today: true)
  wday = WDAY_LIST.fetch(week)
  base_date = Date.today - (include_today ? 0 : 1)
  days_ago = (base_date.wday - wday) % 7

  base_date - days_ago
end

def search_mode(event)
  case event['station_id'].to_s.upcase
  when 'NHK'
    :radiru
  when 'HIBIKI'
    :hibiki
  else
    :radiko
  end
end

def main(event, context)
  mode = search_mode(event)
  is_today = event.fetch('today', true)
  program_date = prev_date_of_week(event['week'].to_sym, include_today: is_today)

  searcher = SEARCHERS.fetch(mode).new(event, program_date)
  programs = searcher.search
  download_func_name = searcher.download_function_name

  # 検索テストモード: 検索結果を通知して処理終了（ダウンロード実行しない）
  if event.fetch('test', false)
    return(
      send_search_notify(
        description:
          "Event\n```json\n#{JSON.pretty_generate(event, ascii_only: false)}\n```\n\nResults\n```json\n#{JSON.pretty_generate(programs, ascii_only: false)}\n```"
      )
    )
  end

  if programs.empty?
    LOGGER.warn("No program found: #{JSON.generate(event, ascii_only: false)}")
    return send_search_notify(status: :warn, description: "#{event['target']}: #{event['keyword']}")
  end

  lambda_client = Aws::Lambda::Client.new
  programs.each do |program|
    lambda_client.invoke(
      function_name: download_func_name,
      invocation_type: 'Event',
      payload: program.to_json
    )

    LOGGER.info(
      "Download requested -> #{download_func_name}: #{JSON.generate(program, ascii_only: false)}"
    )

    notify_program_title =
      if mode == :hibiki
        "#{program[:title]} #{program[:metadata][:title]}"
      else
        program[:metadata][:title]
      end

    send_search_notify(
      status: :info,
      description:
        "#{notify_program_title}\n#{program[:station_id]} / #{program[:ft]}-#{program[:to]}"
    )
  end
end

def lambda_handler(event:, context:)
  main(event, context)
rescue StandardError => e
  LOGGER.error("Error [#{e.class}] #{e.message}")
  LOGGER.error(e.backtrace.join("\n"))
  send_search_notify(status: :error, description: "#{e.class}\n```\n#{e.message}\n```")
end
