# ダウンロード処理
# http gem は各関数の Gemfile で導入する
require 'http'
require 'logger'
require 'uri'
require 'lambdiko/config'

LOGGER = Logger.new($stdout) unless defined?(LOGGER)

# HTTP GET（リトライあり）
# ブロックを渡した場合はレスポンスボディを渡して評価し、その戻り値を返す
# ブロック内で例外が発生した場合もリトライ対象とする
# リトライ上限に達した場合は nil を返す
def fetch_with_retry(url)
  Lambdiko::Config::RETRY_LIMIT.times do |attempt|
    res = HTTP.get(url)
    raise "HTTP #{res.status}" unless res.status.success?

    body = res.body.to_s
    return block_given? ? yield(body) : body
  rescue StandardError => e
    retry_count = attempt + 1
    if retry_count < Lambdiko::Config::RETRY_LIMIT
      LOGGER.warn(
        "Download retry (#{retry_count}/#{Lambdiko::Config::RETRY_LIMIT}): #{e.message} - #{url}"
      )
      sleep 1
    else
      LOGGER.error("Download failed: #{e.message} - #{url}")
    end
  end

  nil
end

# ファイルダウンロード（成功時 true / 失敗時 false）
def download_file(url, file_path)
  fetch_with_retry(url) do |body|
    File.binwrite(file_path, body)
    true
  end || false
end

# 複合キー取得（失敗時は例外）
def download_key(url)
  fetch_with_retry(url) || raise("Key download failed: #{url}")
end

def segment_file_name(url)
  File.basename(URI.parse(url).path)
end

# ffmpeg concat 用セグメントリストファイル作成
def create_segment_list_file(urls, file_dir)
  list_file_path = "#{file_dir}/segment_files.txt"

  File.open(list_file_path, 'w') do |file|
    urls.each { |url| file.puts "file '#{file_dir}/#{segment_file_name(url)}'" }
  end

  list_file_path
end

# セグメント並列ダウンロード
# ブロックを渡した場合、セグメントデータをブロックで変換してから保存する（復号など）
# 戻り値はダウンロードに成功したセグメントのファイルパス配列（URL順）
def download_segments(urls, file_dir, &transform)
  queue = Queue.new
  segment_file_path_list = Array.new(urls.size)

  urls.each_with_index { |url, index| queue << [url, index] }

  threads =
    Lambdiko::Config::THREAD_LIMIT.times.map do
      Thread.new do
        loop do
          begin
            url, index = queue.pop(true)
          rescue ThreadError
            break
          end

          file_path = "#{file_dir}/#{segment_file_name(url)}"
          result =
            fetch_with_retry(url) do |body|
              File.binwrite(file_path, transform ? transform.call(body) : body)
              true
            end
          segment_file_path_list[index] = result ? file_path : nil
        end
      end
    end
  threads.each(&:join)

  failed_count = urls.size - segment_file_path_list.compact.size
  LOGGER.warn("#{failed_count} segment(s) failed to download") if failed_count > 0

  segment_file_path_list.compact
end
