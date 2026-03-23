require 'discordrb/webhooks'
require 'date'
require 'json'
require 'net/http'
require_relative 'config/constants'

API_BASE_URL_TV_GENRE = 'https://program-api.nhk.jp/v3/papiPgGenreTv'
API_BASE_URL_TV_LIST = 'https://program-api.nhk.jp/v3/papiPgDateTv'
API_BASE_URL_RADIO_GENRE = 'https://program-api.nhk.jp/v3/papiPgGenreRadio'
API_BASE_URL_RADIO_LIST = 'https://program-api.nhk.jp/v3/papiPgDateRadio'
EXCLUDE_BS8K_PROGRAMS = (ENV['EXCLUDE_BS8K_PROGRAMS'] == 'True')

def get_parameter(mode)
  case mode
  when :api_key
    parameter_name = ENV['API_KEY_PARAMETER_NAME']
  when :webhook_url
    parameter_name = ENV['WEBHOOK_URL_PARAMETER_NAME']
  end

  query = URI.encode_www_form(name: parameter_name, withDecryption: true)
  uri = URI.parse("http://localhost:2773/systemsmanager/parameters/get?#{query}")
  headers = { 'X-Aws-Parameters-Secrets-Token': ENV['AWS_SESSION_TOKEN'] }

  http = Net::HTTP.new(uri.host, uri.port)
  req = Net::HTTP::Get.new(uri.request_uri)
  req.initialize_http_header(headers)
  res = http.request(req)

  value = JSON.parse(res.body, symbolize_names: true).dig(:Parameter, :Value) if res.code == '200'

  value
end

def get_api_key
  @api_key = get_parameter(:api_key)
end

def get_webhook_url
  @webhook_url = get_parameter(:webhook_url)
end

def is_tv_service?(service_id)
  %w[g g1 g2 e e1 e3 s s1 s2 s5 s6 tv].include?(service_id)
end

def is_radio_service?(service_id)
  %w[r1 r2 r3 radio].include?(service_id)
end

def fetch_programs(date, service_id, area_id, genre_id = nil)
  # Determine if service is TV or Radio
  if is_tv_service?(service_id)
    base_url_genre = API_BASE_URL_TV_GENRE
    base_url_list = API_BASE_URL_TV_LIST
  elsif is_radio_service?(service_id)
    base_url_genre = API_BASE_URL_RADIO_GENRE
    base_url_list = API_BASE_URL_RADIO_LIST
  else
    return []
  end

  date_str = date.strftime('%Y-%m-%d')

  if genre_id
    # ジャンル検索 (v3 query parameter format)
    url =
      "#{base_url_genre}?service=#{service_id}&area=#{area_id}&genre=#{genre_id}&date=#{date_str}&key=#{@api_key}"
  else
    # キーワード検索 (v3 query parameter format)
    url = "#{base_url_list}?service=#{service_id}&area=#{area_id}&date=#{date_str}&key=#{@api_key}"
  end

  response = Net::HTTP.get_response(URI(url))

  return [] unless response.is_a?(Net::HTTPSuccess)

  # Parse v3 response and normalize to internal format
  raw_data = JSON.parse(response.body)
  normalize_v3_response(raw_data, service_id)
end

def normalize_v3_response(raw_data, service_id)
  if service_id == 'tv'
    target_service_id_list = %w[g1 g2 e1 e3 s1 s2 s5 s6]
  elsif service_id == 'radio'
    target_service_id_list = %w[r1 r2 r3]
  else
    target_service_id_list = [service_id]
  end

  programs = { 'list' => {} }
  target_service_id_list.each do |target_service_id|
    # v3 response structure: { "service_id": { "publication": [...], "publishedOn": [...] } }
    next unless raw_data[target_service_id] && raw_data[target_service_id]['publication']

    # Get service and area info from publishedOn
    published_on = raw_data[target_service_id]['publishedOn']&.first || {}
    service_info = published_on['identifierGroup'] || {}

    # Normalize each program to internal format
    normalized_programs =
      raw_data[target_service_id]['publication'].map do |program|
        {
          'id' => program.dig('identifierGroup', 'broadcastEventId'),
          'event_id' => program.dig('identifierGroup', 'eventId'),
          'start_time' => program['startDate'],
          'end_time' => program['endDate'],
          'title' => program['name'],
          'subtitle' => program.dig('identifierGroup', 'tvEpisodeName'),
          'content' => program['description'],
          'service' => {
            'id' => program.dig('identifierGroup', 'serviceId') || service_info['serviceId'],
            'name' => program.dig('identifierGroup', 'serviceName') || service_info['serviceName']
          },
          'area' => {
            'id' => program.dig('identifierGroup', 'areaId') || service_info['areaId'],
            'name' => program.dig('identifierGroup', 'areaName') || service_info['areaName']
          },
          'genres' => (program.dig('identifierGroup', 'genre') || []).map { |g| g['id'] }
        }
      end

    # Return in v2-compatible format for backward compatibility
    programs['list'][target_service_id] = normalized_programs
  end

  return programs
end

def search_programs(programs, params)
  return [] unless programs['list']

  extracted_programs = []
  programs['list'].each do |service, programs|
    programs.each do |program|
      next if EXCLUDE_BS8K_PROGRAMS && program['service']['id'] == 's6'

      if params['genre']
        extracted_programs << program
      else
        # キーワードを含む番組を抽出
        if params['items'].any? { |item| program[item].include?(params['keyword']) }
          extracted_programs << program
        end
      end
    end
  end

  # 放送開始時刻順にソート
  extracted_programs.sort_by! { |program| DateTime.parse(program['start_time']) }

  # サブチャンネルの重複番組を排除
  unique_programs = []
  extracted_programs.each do |program|
    if unique_programs.none? { |p|
         p['title'] == program['title'] && p['start_time'] == program['start_time']
       }
      unique_programs << program
    end
  end

  unique_programs
end

def send_message(params, extracted_programs)
  discord_client = Discordrb::Webhooks::Client.new(url: @webhook_url)

  discord_client.execute do |builder|
    builder.add_embed do |embed|
      if params['genre']
        title = Constants::GENRE[params['genre']]
      else
        title = params['keyword']
      end
      embed.title = "NHK \"#{title}\" の番組放送情報"

      extracted_programs.each do |program|
        area_name = "（#{program['area']['name']}）" unless program['service']['id'].include?('s')

        embed.add_field(
          name: program['title'],
          value:
            "#{Constants::SERVICE[program['service']['id'].to_sym]}#{area_name} / #{DateTime.parse(program['start_time']).strftime('%Y-%m-%d %H:%M')}\n#{program['content']}",
          inline: false
        )
      end

      embed.timestamp = Time.now
    end
  end
end

def lambda_handler(event:, context:)
  get_api_key()
  get_webhook_url()

  event.each do |params|
    date = Date.today + params['days_after']

    params['area'] = 'tokyo' unless params['area']
    area_id = Constants::AREA[params['area'].to_sym]

    programs = fetch_programs(date, params['service'], area_id, params['genre'])

    if programs
      extracted_programs = search_programs(programs, params)

      send_message(params, extracted_programs) if extracted_programs.count > 0
    end
  end
end
