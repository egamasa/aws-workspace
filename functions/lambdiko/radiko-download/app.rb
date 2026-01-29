require 'aws-sdk-s3'
require 'aws-sdk-sns'
require 'base64'
require 'http'
require 'json'
require 'logger'
require 'open3'
require 'securerandom'
require 'time'
require_relative 'lib/radiko'

LOGGER = Logger.new($stdout)
RETRY_LIMIT = 3
THREAD_LIMIT = 3
SEEK_SEC = 300

def to_time(time_str)
  return Time.strptime(time_str, '%Y%m%d%H%M%S')
end

def seek(seek_time, seek_sec = SEEK_SEC)
  sought_time = seek_time + seek_sec
  return sought_time, sought_time.strftime('%Y%m%d%H%M%S')
end

def parse_playlist(playlist)
  list = []

  playlist.to_s.lines.each do |line|
    next if line.strip.empty? || line.strip.start_with?('#')
    list << line.strip
  end

  return list
end

def download_file(url, file_path)
  retry_count = 0
  begin
    File.open(file_path, 'wb') do |file|
      res = HTTP.get(url)
      file.write(res.body)
    end
    return true
  rescue StandardError => e
    retry_count += 1
    if retry_count <= RETRY_LIMIT
      sleep 1
      retry
    else
      return false
    end
  end
end

def create_segment_list_file(urls, file_dir)
  list_file_path = "#{file_dir}/segment_files.txt"

  File.open(list_file_path, 'w') do |file|
    urls.each do |url|
      file_name = File.basename(url)
      file_path = "#{file_dir}/#{file_name}"
      file.puts "file '#{file_path}'"
    end
  end

  return list_file_path
end

def download_segments(urls, file_dir)
  semaphore = Mutex.new
  threads = []
  segment_file_path_list = []

  urls.each_with_index do |url, index|
    file_name = File.basename(url)
    file_path = "#{file_dir}/#{file_name}"

    threads << Thread.new do
      result = download_file(url, file_path)
      semaphore.synchronize { segment_file_path_list[index] = result ? file_path : nil }
    end

    threads.shift.join while threads.size >= THREAD_LIMIT
  end

  threads.each(&:join)

  return segment_file_path_list.compact
end

def build_metadata_options(metadata)
  options = []
  {
    title: metadata['title'],
    artist: metadata['artist'],
    album: metadata['album'],
    album_artist: metadata['album_artist'],
    date: metadata['date'] ? Time.parse(metadata['date']).strftime('%Y-%m-%d') : nil,
    comment: metadata['comment']
  }.each do |key, value|
    next unless value && !value.empty?
    options << '-metadata'
    options << "#{key}=#{value}"
  end

  return options
end

def upload_to_s3(file_path, file_name)
  s3_client = Aws::S3::Client.new
  s3_bucket = ENV['BUCKET_NAME']

  File.open(file_path, 'rb') do |file|
    s3_client.put_object(bucket: s3_bucket, key: file_name, body: file)
  end

  return "s3://#{s3_bucket}/#{file_name}"
end

def sns_publish(message)
  sns = Aws::SNS::Client.new
  sns.publish(topic_arn: ENV['SNS_TOPIC_ARN'], message: message.to_json)
end

def send_notify(status: nil, description: nil, fields: nil)
  title =
    case status
    when :ok
      'ダウンロード完了'
    when :error
      'ダウンロードエラー'
    else
      nil
    end

  message = {
    service: 'Lambdiko',
    title:,
    status: status.to_s.upcase,
    description:,
    fields:,
    timestamp: Time.now
  }
  sns_publish(message)
end

def main(event, context)
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
    playlist_urls = parse_playlist(pre_playlist)

    playlist_urls.each do |playlist_url|
      playlist = HTTP.get(playlist_url)
      segments = parse_playlist(playlist)
      segment_urls.concat(segments)
    end

    seek_time, seek_str = seek(seek_time)
  end

  file_dir = "/tmp/#{lsid}"
  Dir.mkdir(file_dir)
  segment_list_file_path = create_segment_list_file(segment_urls, file_dir)
  segment_file_path_list = download_segments(segment_urls, file_dir)

  if segment_urls.count == segment_file_path_list.count
    output_file_name = "#{event['title']}_#{event['station_id']}_#{event['ft'][0...12]}.m4a"
    output_file_path = "#{file_dir}/#{output_file_name}"

    metadata_options = build_metadata_options(event['metadata'])

    artwork_option = nil
    unless event['metadata']['img'].empty?
      artwork_path = "#{file_dir}/#{File.basename(event['metadata']['img'])}"
      download_file(event['metadata']['img'], artwork_path)
      artwork_option = [
        '-i',
        artwork_path,
        '-map',
        '0:a',
        '-map',
        '1:v',
        '-disposition:1',
        'attached_pic',
        '-id3v2_version',
        '3'
      ]
    end

    ffmpeg_path = '/opt/bin/ffmpeg'
    ffmpeg_cmd = [
      ffmpeg_path,
      '-hide_banner',
      '-y',
      '-safe',
      '0',
      '-f',
      'concat',
      '-i',
      segment_list_file_path
    ]
    ffmpeg_cmd.concat(artwork_option) if artwork_option
    ffmpeg_cmd.concat(metadata_options)
    ffmpeg_cmd.concat(['-c', 'copy', output_file_path])

    begin
      _, stderr, status = Open3.capture3(*ffmpeg_cmd)

      unless status.success?
        LOGGER.error("FFmpeg failed: #{stderr}")
        send_notify(status: :error, description: "FFmpeg: #{output_file_name}\n```\n#{stderr}\n```")
        return
      end
    rescue => e
      LOGGER.error("FFmpeg Error: #{e.message}")
      send_notify(
        status: :error,
        description: "FFmpeg: #{output_file_name}\n```\n#{e.message}\n```"
      )
      return
    end
  else
    LOGGER.error('Failed to download segments')
    send_notify(status: :error, description: "Download segments: #{output_file_name}")
    return
  end

  begin
    s3_file_path = upload_to_s3(output_file_path, output_file_name)

    file_size = "#{(File.size(output_file_path).to_f / 1024 / 1024).round(2)} MB"
    LOGGER.info("Download completed: #{s3_file_path} (#{file_size})")

    fields = [
      { name: 'File', value: s3_file_path, inline: false },
      { name: 'Size', value: file_size, inline: true }
    ]
    send_notify(status: :ok, fields: fields)
  rescue => e
    LOGGER.error("Failed to upload to S3: #{output_file_path} - #{e.message}")
    send_notify(
      status: :error,
      description: "S3 Upload: #{output_file_name}\n```\n#{e.message}\n```"
    )
  end
end

def lambda_handler(event:, context:)
  main(event, context)
end
