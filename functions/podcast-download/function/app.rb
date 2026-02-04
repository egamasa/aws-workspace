require 'aws-sdk-s3'
require 'aws-sdk-sns'
require 'logger'
require 'mp3info'
require 'open-uri'
require 'rss'
require 'securerandom'
require 'time'
require 'uri'

RETRY_LIMIT = 3
LOGGER = Logger.new($stdout)

def download_file(url, file_path)
  retry_count = 0

  begin
    URI.open(url) { |res| File.open(file_path, 'wb') { |file| file.write(res.read) } }
  rescue => e
    retry_count += 1
    if retry_count <= RETRY_LIMIT
      sleep 1
      retry
    else
      raise e
    end
  end
end

def remove_html_tags(text)
  text.to_s.gsub(%r{</?[^>]+?>}, '').gsub(/\s+/, ' ').strip
end

def zenkaku_to_hankaku(text)
  text.to_s.tr('Ａ-Ｚａ-ｚ０-９　', 'A-Za-z0-9 ')
end

def get_file_ext(url)
  File.extname(URI.parse(url).path)
end

def sanitize_filename(filename)
  filename.gsub(%r{[/\:*?"<>|]}, '_')
end

def utc_to_jst(time)
  time.getlocal('+09:00')
end

def update_mp3tags(file_path, channel, item, event)
  Mp3Info.open(file_path) do |mp3|
    mp3.tag2.TIT2 = zenkaku_to_hankaku(item.title)
    mp3.tag2.TPE1 = event['artist'] if event['artist']
    mp3.tag2.TALB = event['album'] if event['album']
    mp3.tag2.TPE2 = event['album_artist'] || item.itunes_author
    mp3.tag2.TCON = event['genre'] || channel.itunes_category&.text || 'Podcast'
    mp3.tag2.TDRC = event['year'] || utc_to_jst(item.pubDate).strftime('%Y')
    mp3.tag2.COMM = event['comment'] || remove_html_tags(item.description)
  end
end

def upload_to_s3(file_path, file_name)
  s3_client = Aws::S3::Client.new
  s3_bucket = ENV['BUCKET_NAME']

  File.open(file_path, 'rb') do |file|
    s3_client.put_object(bucket: s3_bucket, key: file_name, body: file)
  end

  "s3://#{s3_bucket}/#{file_name}"
end

def sns_publish(message)
  sns = Aws::SNS::Client.new
  sns.publish(topic_arn: ENV['SNS_TOPIC_ARN'], message: message.to_json)
end

def send_notify(status:, description:, fields:)
  title = status == :ok ? 'ダウンロード完了' : 'ダウンロードエラー'

  message = {
    service: 'Podcast Download',
    title:,
    status: status.to_s.upcase,
    description:,
    fields:,
    timestamp: Time.now
  }
  sns_publish(message)
end

def main(event, context)
  rss_url = event['rss_url']

  begin
    rss_xml = URI.open(rss_url).read
    rss = RSS::Parser.parse(rss_xml, false)
  rescue => e
    LOGGER.error("Failed to fetch or parse RSS: #{e.message} - #{rss_url}")

    if ENV['SNS_TOPIC_ARN']
      fields = [{ name: 'Error', value: e.message, inline: false }]
      send_notify(status: :error, description: rss_url, fields: fields)
    end

    return
  end

  channel = rss.channel
  title = event['title'] || zenkaku_to_hankaku(channel.title)
  items = event['mode'] == 'all' ? rss.items : [rss.items.first]

  items.each do |item|
    next unless item.enclosure

    audio_url = item.enclosure.url
    audio_ext = get_file_ext(audio_url)

    item_date = utc_to_jst(item.pubDate)

    file_dir = "/tmp/#{SecureRandom.uuid}"
    Dir.mkdir(file_dir)

    file_name = sanitize_filename("#{title}_#{item_date.strftime('%Y%m%d%H%M')}#{audio_ext}")
    file_path = "#{file_dir}/#{file_name}"

    begin
      download_file(audio_url, file_path)
    rescue => e
      LOGGER.error("Failed to download: #{e.message} - #{audio_url}")

      if ENV['SNS_TOPIC_ARN']
        fields = [{ name: 'Error', value: e.message, inline: false }]
        send_notify(status: :error, description: audio_url, fields: fields)
      end

      next
    end

    if audio_ext.downcase == '.mp3'
      begin
        update_mp3tags(file_path, channel, item, event)
      rescue => e
        LOGGER.error("Failed to update MP3 tags: #{e.message}")
      end
    end

    begin
      s3_file_path = upload_to_s3(file_path, file_name)

      file_size = "#{(File.size(file_path).to_f / 1024 / 1024).round(2)} MB"
      LOGGER.info("Download completed: #{file_name} (#{file_size})")

      if ENV['SNS_TOPIC_ARN']
        fields = [
          { name: 'Episode', value: zenkaku_to_hankaku(item.title), inline: false },
          { name: 'Size', value: file_size, inline: true }
        ]
        send_notify(status: :ok, description: s3_file_path, fields: fields)
      end
    rescue => e
      LOGGER.error("Failed to upload to S3: #{e.message}")

      if ENV['SNS_TOPIC_ARN']
        fields = [{ name: 'Error', value: e.message, inline: false }]
        send_notify(status: :error, description: file_name, fields: fields)
      end
    ensure
      File.delete(file_path) if File.exist?(file_path)
    end
  end
end

def lambda_handler(event:, context:)
  main(event, context)
end
