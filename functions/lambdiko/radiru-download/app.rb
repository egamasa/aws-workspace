unless File.exist?('/opt/ruby/lib/lambdiko')
  $LOAD_PATH.unshift(File.expand_path('../layers/ruby', __dir__))
end

require 'fileutils'
require 'http'
require 'json'
require 'logger'
require 'securerandom'
require 'time'
require 'lambdiko/download'
require 'lambdiko/ffmpeg'
require 'lambdiko/hls'
require 'lambdiko/metadata'
require 'lambdiko/notify'
require 'lambdiko/s3'

LOGGER = Logger.new($stdout)
RETRY_LIMIT = 3
THREAD_LIMIT = 3
WDAY_JA = %w[日 月 火 水 木 金 土].freeze
# プレイリストに IV 指定がない場合の初期化ベクトル（従来実装の値を踏襲）
DEFAULT_IV = '0000000000000000'

def to_time(time_str)
  Time.strptime(time_str, '%Y%m%d%H%M%S')
end

def sanitize_filename(filename)
  filename.to_s.gsub(%r{[/\\:*?"<>|]}, '_')
end

def format_airtime(ft_str, to_str)
  ft = to_time(ft_str)
  to = to_time(to_str)

  date = ft.to_date

  ft_hh = ft.hour.to_s.rjust(2, '0')
  ft_mm = ft.strftime('%M')
  to_hh = to.hour.to_s.rjust(2, '0')
  to_mm = to.strftime('%M')

  {
    file_name: "#{date.strftime('%Y%m%d')}#{ft_hh}#{ft_mm}",
    notify: "#{date.strftime('%Y-%m-%d')}（#{WDAY_JA[date.wday]}）#{ft_hh}:#{ft_mm}-#{to_hh}:#{to_mm}"
  }
end

def main(event, context)
  file_dir = nil

  begin
    stream_url = event['stream_url']
    base_url = stream_url.match(%r{^(https://.*/)}).to_s

    pre_playlist = HTTP.get(stream_url)
    playlist_urls = parse_hls_playlist(pre_playlist)[:segments]

    raise 'No playlist URLs found' if playlist_urls.empty?

    file_dir = "/tmp/#{SecureRandom.uuid}"
    Dir.mkdir(file_dir) unless Dir.exist?(file_dir)

    segment_urls = []
    segment_files_count = 0

    playlist_urls.each do |playlist_url|
      playlist = HTTP.get("#{base_url}#{playlist_url}")
      parsed = parse_hls_playlist(playlist, base_url)
      playlist_segment_urls = parsed[:segments]
      segment_urls.concat(playlist_segment_urls)

      key = download_key(parsed[:key_uri])
      iv = parsed[:iv] || DEFAULT_IV
      segment_file_path_list =
        download_segments(playlist_segment_urls, file_dir) { |data| decrypt_aes128(data, key, iv) }
      segment_files_count += segment_file_path_list.count
    end

    segment_list_file_path = create_segment_list_file(segment_urls, file_dir)

    raise 'Segment count mismatch' unless segment_urls.count == segment_files_count

    airtime = format_airtime(event['ft'], event['to'])

    output_file_name =
      "#{sanitize_filename(event['title'])}_#{event['station_id']}_#{airtime[:file_name]}.m4a"
    output_file_path = "#{file_dir}/#{output_file_name}"

    metadata_options = build_metadata_options(event['metadata'])
    artwork_option = build_artwork_option(event['metadata'], file_dir)

    run_ffmpeg(segment_list_file_path, output_file_path, metadata_options, artwork_option)

    s3_file_path = upload_to_s3(output_file_path, output_file_name)

    file_size = "#{(File.size(output_file_path).to_f / 1024 / 1024).round(2)} MB"
    duration = probe_duration(output_file_path)

    LOGGER.info("Download completed: #{s3_file_path} (#{file_size} / #{duration})")

    fields = [
      { name: 'Title', value: event['metadata']['title'], inline: false },
      { name: 'On Air', value: airtime[:notify], inline: true },
      { name: 'Size', value: "#{file_size} / #{duration}", inline: true }
    ]
    send_download_notify(status: :ok, description: s3_file_path, fields: fields)
  ensure
    FileUtils.rm_rf(file_dir) if file_dir && Dir.exist?(file_dir)
  end
end

def lambda_handler(event:, context:)
  main(event, context)
rescue StandardError => e
  LOGGER.error("Error [#{e.class}] #{e.message}")
  LOGGER.error(e.backtrace.join("\n"))
  send_download_notify(status: :error, description: "#{e.class}\n```\n#{e.message}\n```")
end
