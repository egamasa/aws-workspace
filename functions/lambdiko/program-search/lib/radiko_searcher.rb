require 'lambdiko/common'
require_relative 'http_helper'

# radiko 番組検索
class RadikoSearcher
  include HttpHelper

  def initialize(event, program_date)
    @event = event
    @program_date = program_date
  end

  def download_function_name
    ENV['RADIKO_DL_FUNC_NAME']
  end

  # 番組表から target フィールドに keyword を含む番組を抽出
  def search
    xml_doc = program_xml(@program_date, @event['station_id'])
    station_name = parse_station_name(xml_doc)
    target = @event['target']
    keyword = @event['keyword']

    xml_doc
      .elements
      .to_a('//progs/prog')
      .select { |prog| prog.elements[target]&.text&.include?(keyword) }
      .map { |prog| build_program(prog, xml_doc, station_name) }
  end

  private

  # 番組表（日付・放送局ID指定）取得
  def program_xml(date, station_id)
    url = "https://radiko.jp/v3/program/station/date/#{date.strftime('%Y%m%d')}/#{station_id}.xml"
    http_get_xml(url)
  end

  # 番組表から放送局名抽出
  # station_id を省略した場合は最初の station を対象とする
  # 該当する放送局がない場合は nil を返す
  def parse_station_name(xml_doc, station_id = nil)
    stations = xml_doc.elements.to_a('//station')
    station = station_id ? stations.find { |s| s.attributes['id'] == station_id } : stations.first

    station && station.elements['name']&.text
  end

  def build_program(prog, xml_doc, station_name)
    custom_title = @event['title']

    {
      title: custom_title || prog.elements['title']&.text,
      station_id: @event['station_id'],
      ft: prog.attributes['ft'],
      to: prog.attributes['to'],
      metadata: {
        title: prog.elements['title']&.text,
        artist: prog.elements['pfm']&.text,
        album: custom_title || prog.elements['title']&.text,
        album_artist: station_name,
        date: xml_doc.elements['//progs/date']&.text,
        comment:
          "#{remove_html_tags(prog.elements['desc']&.text)}#{remove_html_tags(prog.elements['info']&.text)}",
        img: prog.elements['img']&.text
      }
    }
  end
end
