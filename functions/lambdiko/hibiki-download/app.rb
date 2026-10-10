unless File.exist?('/opt/ruby/lib/lambdiko')
  $LOAD_PATH.unshift(File.expand_path('../layers/ruby', __dir__))
end

require 'fileutils'
require 'http'
require 'json'
require 'logger'
require 'securerandom'
require 'time'
require 'lambdiko/config'
require 'lambdiko/datetime'
require 'lambdiko/download'
require 'lambdiko/ffmpeg'
require 'lambdiko/hls'
require 'lambdiko/metadata'
require 'lambdiko/notify'
require 'lambdiko/s3'

LOGGER = Logger.new($stdout) unless defined?(LOGGER)

# API
def get_hibiki_stream(video_id)
  url = "https://vcms-api.hibiki-radio.jp/api/v1/videos/play_check?video_id=#{video_id}"
  res = HTTP.headers(Lambdiko::Config::HIBIKI_API_HEADERS).get(url)
  raise "Failed to fetch stream info: HTTP #{res.code}" unless res.status.success?

  JSON.parse(res.body.to_s)
end

def main(event, _context)
  file_dir = nil

  begin
    # event['to'] に video_id が格納されている
    video_id = event['to']
    stream_info = get_hibiki_stream(video_id)

    res = HTTP.get(stream_info['playlist_url'])

    # 動画番組は画質違いのバリアントが複数配信される
    # 全て処理すると同じ番組が重複するため、最小 BANDWIDTH の1つのみを使う
    playlist_url = parse_hls_master_playlist(res.body, lowest_bandwidth_only: true).first

    raise 'No playlist URLs found' if playlist_url.nil?

    file_dir = "/tmp/#{SecureRandom.uuid}"
    Dir.mkdir(file_dir) unless Dir.exist?(file_dir)

    base_url = playlist_url.match(%r{^(https?://[^?]+/)}).to_s
    playlist = HTTP.get(playlist_url)
    parsed = parse_hls_playlist(playlist.body, base_url)
    segment_urls = parsed[:segments]

    key = download_key(parsed[:key_uri])
    iv = parsed[:iv]
    segment_file_path_list =
      download_segments(segment_urls, file_dir) { |data| decrypt_aes128(data, key, iv) }

    segment_list_file_path = create_segment_list_file(segment_urls, file_dir)

    raise 'Segment count mismatch' unless segment_urls.count == segment_file_path_list.count

    airtime = format_airtime(event['ft'])

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
