require 'time'
require 'lambdiko/common'
require_relative 'http_helper'

# らじる★らじる 番組検索（番組タイトルのみ対応）
class RadiruSearcher
  include HttpHelper

  def initialize(event, program_date)
    @event = event
    @program_date = program_date
  end

  def download_function_name
    ENV['RADIRU_DL_FUNC_NAME']
  end

  # 番組表（日付指定）から番組タイトルに keyword を含む番組を抽出
  def search
    list = program_list(@program_date)
    onair_date = list['onair_date']
    custom_title = @event['title']

    list['corners']
      .select { |prog| prog['title']&.include?(@event['keyword']) }
      .flat_map do |program|
        program_info = get_program_info(program)

        program_info['episodes'].filter_map do |episode|
          ft, to = parse_aa_contents_id(episode['aa_contents_id'])
          next unless ft.include?(onair_date)

          build_program(program_info, episode, ft, to, onair_date, custom_title)
        end
      end
  end

  private

  # 番組表（日付指定）取得
  def program_list(date)
    url =
      "https://www.nhk.or.jp/radio-api/app/v1/web/ondemand/corners?onair_date=#{date.strftime('%Y%m%d')}"
    http_get_json(url)
  end

  # 番組情報取得
  def get_program_info(program)
    url =
      "https://www.nhk.or.jp/radio-api/app/v1/web/ondemand/series?site_id=#{program['series_site_id']}&corner_site_id=#{program['corner_site_id']}"
    http_get_json(url)
  end

  # 番組開始＆終了時刻抽出
  def parse_aa_contents_id(aa_contents_id)
    data = aa_contents_id.split(';')
    start_time = Time.strptime(data[4][/^[^_]+/], '%Y-%m-%dT%H:%M:%S%z')
    end_time = Time.strptime(data[4][/[^_]+$/], '%Y-%m-%dT%H:%M:%S%z')

    [start_time.strftime('%Y%m%d%H%M00'), end_time.strftime('%Y%m%d%H%M00')]
  end

  def build_program(program_info, episode, ft, to, onair_date, custom_title)
    station_id =
      (
        if program_info['radio_broadcast'].split(',').count == 1
          "NHK-#{program_info['radio_broadcast']}"
        else
          'NHK'
        end
      )

    {
      title: custom_title || program_info['title'],
      station_id: station_id,
      ft: ft,
      to: to,
      stream_url: episode['stream_url'],
      metadata: {
        title: zenkaku_to_hankaku(episode['program_title']),
        artist: nil,
        album: custom_title || program_info['title'],
        album_artist: 'NHK',
        date: onair_date,
        comment: remove_html_tags(program_info['series_description']),
        img: program_info['thumbnail_url']
      }
    }
  end
end
