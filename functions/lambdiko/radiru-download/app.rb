require 'aws-sdk-s3'
require 'aws-sdk-sns'
require 'http'
require 'json'
require 'logger'
require 'open3'
require 'openssl'
require 'securerandom'
require 'uri'

LOGGER = Logger.new($stdout)
RETRY_LIMIT = 3
THREAD_LIMIT = 3

def parse_playlist(playlist, base_url = nil)
  list = []
  key_uri = nil
  iv = '0000000000000000' # 16bit

  playlist.to_s.lines.each do |line|
    next if line.strip.empty?

    # 複合キーURI・初期化ベクトル抽出
    if line.start_with?('#EXT-X-KEY')
      key_uri = line.match(/URI="(.*?)"/)[1]
      iv = [line.match(/IV=(.*)/)[1]].pack('H*') if line.include?('IV=')
    end

    next if line.strip.start_with?('#')
    list << "#{base_url}#{line.strip}"
  end

  return list, key_uri, iv
end

# セグメント復号
def decrypt_aes128(data)
  cipher = OpenSSL::Cipher.new('aes-128-cbc')
  cipher.decrypt
  cipher.key = @key
  cipher.iv = @iv
  cipher.update(data) + cipher.final
end

def download_file(url, file_path, mode = :file)
  retry_count = 0
  begin
    res = HTTP.get(url)

    case mode
    when :file
      File.open(file_path, 'wb') { |file| file.write(res.body) }
      return true
    when :key
      return res.body.to_s
    when :segment
      data = res.to_s
      decrypted_data = decrypt_aes128(data)
      File.open(file_path, 'wb') { |file| file.write(decrypted_data) }
      return true
    end
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

# ffmpeg 結合用ファイルリスト作成
def create_segment_list_file(urls, file_dir)
  list_file_path = "#{file_dir}/segment_files.txt"

  File.open(list_file_path, 'w') do |file|
    urls.each do |url|
      file_name = File.basename(URI.parse(url).path)
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

  urls.each do |url|
    file_name = File.basename(URI.parse(url).path)
    file_path = "#{file_dir}/#{file_name}"

    threads << Thread.new do
      result = semaphore.synchronize { download_file(url, file_path, :segment) }
      segment_file_path_list << file_path if result
    end

    threads.shift.join while threads.size >= THREAD_LIMIT
  end

  threads.each(&:join)

  return segment_file_path_list
end

# ffmpeg メタデータ追加コマンド出力
def build_metadata_options(metadata)
  options = []
  {
    title: metadata['title'],
    artist: metadata['artist'],
    album: metadata['album'],
    album_artist: metadata['album_artist'],
    date: Time.parse(metadata['date']).strftime('%Y-%m-%d'),
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
  stream_url = event['stream_url']
  base_url = stream_url.match(%r{^(https://.*/)}).to_s

  pre_playlist = HTTP.get(stream_url)
  playlist_urls, *_ = parse_playlist(pre_playlist)

  file_dir = "/tmp/#{SecureRandom.uuid}"
  Dir.mkdir(file_dir)

  segment_urls = []
  segment_files_count = 0

  playlist_urls.each do |playlist_url|
    playlist = HTTP.get("#{base_url}#{playlist_url}")
    playlist_segment_urls, key_uri, @iv = parse_playlist(playlist, base_url)
    segment_urls.concat(playlist_segment_urls)

    @key = download_file(key_uri, nil, :key)
    segment_file_path_list = download_segments(playlist_segment_urls, file_dir)
    segment_files_count += segment_file_path_list.count
  end

  segment_list_file_path = create_segment_list_file(segment_urls, file_dir)

  if segment_urls.count == segment_files_count
    output_file_name = "#{event['title']}_#{event['station_id']}_#{event['ft'][0...12]}.m4a"
    output_file_path = "#{file_dir}/#{output_file_name}"

    metadata_options = build_metadata_options(event['metadata'])

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
    else
      artwork_path = nil
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
    ffmpeg_cmd.concat(artwork_option) if artwork_path
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
