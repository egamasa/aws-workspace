unless File.exist?('/opt/ruby/lib/lambdiko')
  $LOAD_PATH.unshift(File.expand_path('../layers/ruby', __dir__))
end

require 'fileutils'
require 'http'
require 'json'
require 'logger'
require 'securerandom'
require 'time'
require 'lambdiko/datetime'
require 'lambdiko/download'
require 'lambdiko/ffmpeg'
require 'lambdiko/hls'
require 'lambdiko/metadata'
require 'lambdiko/notify'
require 'lambdiko/s3'
require_relative 'lib/radiko'

LOGGER = Logger.new($stdout)
RETRY_LIMIT = 3
THREAD_LIMIT = 3
SEEK_SEC = 300

def seek(seek_time, seek_sec = SEEK_SEC)
  sought_time = seek_time + seek_sec
  [sought_time, sought_time.strftime('%Y%m%d%H%M%S')]
end

def main(event, context)
  file_dir = nil

  begin
    client = Radiko::Client.new
    area_id = client.get_area_id_by_station_id(event['station_id'])
    stream_info = client.get_timefree_stream_info(event['station_id'])

    lsid = SecureRandom.hex(16)
    headers = { 'X-Radiko-AreaId' => area_id, 'X-Radiko-AuthToken' => stream_info[:auth_token] }
    params = {
      lsid: lsid,
      station_id: event['station_id'],
      l: SEEK_SEC.to_s,
      start_at: event['ft'],
      end_at: event['to'],
      type: 'b',
      ft: event['ft'],
      to: event['to']
    }

    segment_urls = []
    seek_time = to_time(event['ft'])
    seek_str = event['ft']
    end_time = to_time(event['to'])

    while seek_time < end_time
      params[:seek] = seek_str
      pre_playlist = HTTP.headers(headers).get(stream_info[:url], params:)
      playlist_urls = parse_hls_playlist(pre_playlist)[:segments]

      playlist_urls.each do |playlist_url|
        playlist = HTTP.get(playlist_url)
        segment_urls.concat(parse_hls_playlist(playlist)[:segments])
      end

      seek_time, seek_str = seek(seek_time)
    end

    file_dir = "/tmp/#{lsid}"
    Dir.mkdir(file_dir) unless Dir.exist?(file_dir)
    segment_list_file_path = create_segment_list_file(segment_urls, file_dir)
    segment_file_path_list = download_segments(segment_urls, file_dir)

    raise 'Segment count mismatch' unless segment_urls.count == segment_file_path_list.count

    airtime = format_airtime_radiko(event['ft'], event['to'])

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
