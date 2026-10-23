require 'lambdiko/common'
require 'lambdiko/config'
require_relative 'http_helper'

# 響 - HiBiKi Radio Station 番組検索
class HibikiSearcher
  include HttpHelper

  API_BASE_URL = 'https://vcms-api.hibiki-radio.jp/api/v1'.freeze
  API_HEADERS = Lambdiko::Config::HIBIKI_API_HEADERS

  # 曜日 → 響 API の day_of_week
  # 響は土・日曜日を1つのカテゴリ（6）としてまとめているため、sat / sun はどちらも 6
  DAY_OF_WEEK = { mon: 1, tue: 2, wed: 3, thu: 4, fri: 5, sat: 6, sun: 6 }.freeze

  # 響は曜日指定で番組表を取得するため program_date は使用しない
  def initialize(event, _program_date = nil)
    @event = event
  end

  def download_function_name
    ENV['HIBIKI_DL_FUNC_NAME']
  end

  # 番組表（曜日指定）から targets のいずれかのフィールドに keyword を含む番組を抽出
  # target は Array（複数指定可能）
  def search
    targets = Array(@event['target'] || 'name')
    keyword = @event['keyword']

    program_list(@event['week'])
      .select { |program| targets.any? { |target| program[target]&.to_s&.include?(keyword) } }
      .map { |program| build_program(get_program_info(program['access_id'])) }
  end

  private

  # 番組表（曜日指定）取得
  def program_list(wday)
    day =
      DAY_OF_WEEK.fetch(wday.to_s.to_sym) do
        raise ArgumentError, "Unsupported week for HiBiKi: #{wday}"
      end

    http_get_json("#{API_BASE_URL}/programs?day_of_week=#{day}", API_HEADERS)
  end

  # 番組情報取得
  def get_program_info(access_id)
    http_get_json("#{API_BASE_URL}/programs/#{access_id}", API_HEADERS)
  end

  def build_program(program_info)
    custom_title = @event['title']
    title = custom_title || program_info['name'].tr('　', ' ').squeeze(' ')

    {
      title: title,
      station_id: 'HiBiKi',
      ft: program_info['episode_updated_at']&.delete('^0-9') || '',
      # 終了時刻データは存在しないため、to は video_id の送信に使用する
      to: program_info['episode']['video']['id'],
      metadata: {
        title: program_info['episode']['name'],
        artist: program_info['cast'],
        album: title,
        album_artist: 'HiBiKi Radio Station',
        date: program_info['episode_updated_at']&.delete('^0-9')&.[](0..7) || '',
        comment:
          remove_html_tags(
            program_info['episode']['episode_parts']
              &.[](0)
              &.[]('description')
              .to_s
              .tr('　', ' ')
              .squeeze(' ')
          ),
        img: program_info['sp_image_url']
      }
    }
  end
end
