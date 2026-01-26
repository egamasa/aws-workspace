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
    # タイトル
    mp3.tag2.TIT2 = zenkaku_to_hankaku(item.title)

    # アーティスト
    mp3.tag2.TPE1 = event['artist'] if event['artist']

    # アルバム
    mp3.tag2.TALB = event['album'] if event['album']

    # アルバムアーティスト
    if event['album_artist']
      mp3.tag2.TPE2 = event['album_artist']
    else
      mp3.tag2.TPE2 = item.itunes_author
    end

    # ジャンル
    if event['genre']
      mp3.tag2.TCON = event['genre']
    else
      mp3.tag2.TCON = channel.itunes_category.text
    end

    # 年
    if event['year']
      mp3.tag2.TDRC = event['year']
    else
      mp3.tag2.TDRC = utc_to_jst(item.pubDate).strftime('%Y')
    end

    # コメント
    if event['comment']
      mp3.tag2.COMM = event['comment']
    else
      mp3.tag2.COMM = remove_html_tags(item.description)
    end
  end
end

def upload_to_s3(file_path, file_name)
  s3_client = Aws::S3::Client.new
  s3_bucket = ENV['BUCKET_NAME']
  file_content = File.open(file_path, 'rb')

  s3_client.put_object(bucket: s3_bucket, key: file_name, body: file_content)
end

def sns_publish(message)
  sns = Aws::SNS::Client.new
  sns.publish(topic_arn: ENV['SNS_TOPIC_ARN'], message: message.to_json)
end

def send_notify(status:, audio_url: nil, file_name: nil, item_title: nil, error_msg: nil)
  title = 'Podcast Download'
  description =
    if status == :ok
      'ダウンロード完了'
    elsif audio_url
      'ダウンロードエラー'
    else
      '保存エラー'
    end

  fields = []
  if status == :ok
    fields << { name: 'File', value: file_name, inline: false }
    fields << { name: 'Episode', value: item_title, inline: false }
  elsif audio_url
    fields << { name: 'URL', value: audio_url, inline: false }
    fields << { name: 'Error', value: error_msg, inline: false }
  else
    fields << { name: 'File', value: file_name, inline: false }
    fields << { name: 'Error', value: error_msg, inline: false }
  end

  message = { title:, status: status.to_s.upcase, description:, fields:, timestamp: Time.now }

  sns_publish(message)
end

def main(event, context)
  rss_url = event['rss_url']
  rss_xml = URI.open(rss_url).read
  rss = RSS::Parser.parse(rss_xml, false)

  channel = rss.channel

  if event['title']
    title = event['title']
  else
    title = zenkaku_to_hankaku(channel.title)
  end

  if event['mode'] == 'all'
    items = rss.items
  else
    items = [rss.items.first]
  end

  items.each do |item|
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
      LOGGER.error("Failed to download: #{e.message}")
      send_notify(status: :error, audio_url:, error_msg: e.message) if ENV['SNS_TOPIC_ARN']
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
      res = upload_to_s3(file_path, file_name)
      if res.etag
        LOGGER.info("Download completed: #{file_name}")
        if ENV['SNS_TOPIC_ARN']
          send_notify(status: :ok, file_name:, item_title: zenkaku_to_hankaku(item.title))
        end
      end
    rescue => e
      LOGGER.error("Failed to upload to S3: #{e.message}")
      send_notify(status: :error, file_name:, error_msg: e.message) if ENV['SNS_TOPIC_ARN']
    ensure
      File.delete(file_path) if File.exist?(file_path)
    end
  end
end

def lambda_handler(event:, context:)
  main(event, context)
end
