require 'lambdiko/common'
require 'radiko/client'

# radiko 番組検索
class RadikoSearcher
  def initialize(event, program_date, client: Radiko::Client.new)
    @event = event
    @program_date = program_date
    @client = client
  end

  def download_function_name
    ENV['RADIKO_DL_FUNC_NAME']
  end

  # 番組表から target フィールドに keyword を含む番組を抽出
  def search
    xml_doc = @client.get_program_xml(@program_date, @event['station_id'])
    station_name = @client.parse_station_name(xml_doc)
    target = @event['target']
    keyword = @event['keyword']

    xml_doc
      .elements
      .to_a('//progs/prog')
      .select { |prog| prog.elements[target]&.text&.include?(keyword) }
      .map { |prog| build_program(prog, xml_doc, station_name) }
  end

  private

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
