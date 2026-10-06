require 'spec_helper'
require 'tmpdir'
require 'lambdiko/download'

RSpec.describe 'Lambdiko::Download' do
  let(:retry_limit) { Lambdiko::Config::RETRY_LIMIT }

  # HTTP.get の戻り値を模したレスポンス
  def http_response(success: true, body: '', status_text: '200 OK')
    status = instance_double('HTTP::Response::Status', success?: success, to_s: status_text)
    instance_double('HTTP::Response', status: status, body: body)
  end

  def failed_response
    http_response(success: false, status_text: '500 Internal Server Error')
  end

  # 各テストで一時ディレクトリを使用し、終了後に削除する
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  before do
    allow(LOGGER).to receive(:warn)
    allow(LOGGER).to receive(:error)
    # リトライ間隔の待機をスキップ
    allow(self).to receive(:sleep)
  end

  describe '#fetch_with_retry' do
    let(:url) { 'https://example.com/file' }

    it '成功したときレスポンスボディを文字列で返す' do
      allow(HTTP).to receive(:get).with(url).and_return(http_response(body: 'content'))

      expect(fetch_with_retry(url)).to eq('content')
    end

    it 'ブロックを渡すとボディを渡して評価し、その戻り値を返す' do
      allow(HTTP).to receive(:get).with(url).and_return(http_response(body: 'content'))

      expect(fetch_with_retry(url, &:upcase)).to eq('CONTENT')
    end

    it '失敗後にリトライして成功したらその結果を返す' do
      allow(HTTP).to receive(:get).with(url).and_return(
        failed_response,
        http_response(body: 'content')
      )

      expect(fetch_with_retry(url)).to eq('content')
      expect(HTTP).to have_received(:get).twice
      expect(LOGGER).to have_received(:warn).with(/Download retry \(1\/#{retry_limit}\).*#{url}/)
    end

    it 'HTTP ステータスが成功以外のときはリトライ上限まで試行して nil を返す' do
      allow(HTTP).to receive(:get).with(url).and_return(failed_response)

      expect(fetch_with_retry(url)).to be_nil
      expect(HTTP).to have_received(:get).exactly(retry_limit).times
      expect(LOGGER).to have_received(:error).once.with(/Download failed: HTTP 500.*#{url}/)
    end

    it '通信エラーが発生したときもリトライ対象とする' do
      allow(HTTP).to receive(:get).with(url).and_raise(IOError, 'connection reset')

      expect(fetch_with_retry(url)).to be_nil
      expect(HTTP).to have_received(:get).exactly(retry_limit).times
    end

    it 'ブロック内で例外が発生したときもリトライ対象とする' do
      allow(HTTP).to receive(:get).with(url).and_return(http_response(body: 'content'))
      attempts = 0

      result =
        fetch_with_retry(url) do |body|
          attempts += 1
          raise 'write failed' if attempts < 2

          body
        end

      expect(result).to eq('content')
      expect(attempts).to eq(2)
    end
  end

  describe '#download_file' do
    let(:url) { 'https://example.com/image.jpg' }

    it 'ダウンロードした内容をファイルに保存して true を返す' do
      allow(HTTP).to receive(:get).with(url).and_return(http_response(body: "\x00\x01binary"))
      file_path = "#{@dir}/image.jpg"

      expect(download_file(url, file_path)).to be(true)
      expect(File.binread(file_path)).to eq("\x00\x01binary".b)
    end

    it 'ダウンロードに失敗したらファイルを作成せず false を返す' do
      allow(HTTP).to receive(:get).with(url).and_return(failed_response)
      file_path = "#{@dir}/image.jpg"

      expect(download_file(url, file_path)).to be(false)
      expect(File.exist?(file_path)).to be(false)
    end
  end

  describe '#download_key' do
    let(:url) { 'https://example.com/key.bin' }

    it '復号キーをバイナリ文字列で返す' do
      allow(HTTP).to receive(:get).with(url).and_return(http_response(body: '0123456789abcdef'))

      expect(download_key(url)).to eq('0123456789abcdef')
    end

    it 'ダウンロードに失敗したら例外を発生させる' do
      allow(HTTP).to receive(:get).with(url).and_return(failed_response)

      expect { download_key(url) }.to raise_error(RuntimeError, /Key download failed: #{url}/)
    end
  end

  describe '#create_segment_list_file' do
    it 'ffmpeg concat 用のセグメントリストファイルを作成してパスを返す' do
      urls = %w[https://example.com/a/seg1.aac https://example.com/a/seg2.aac]

      path = create_segment_list_file(urls, @dir)

      expect(path).to eq("#{@dir}/segment_files.txt")
      expect(File.read(path)).to eq("file '#{@dir}/seg1.aac'\nfile '#{@dir}/seg2.aac'\n")
    end

    it 'URLのクエリ文字列を除いたファイル名を使用する' do
      path = create_segment_list_file(%w[https://example.com/a/seg1.aac?token=abc], @dir)

      expect(File.read(path)).to eq("file '#{@dir}/seg1.aac'\n")
    end

    it 'URLが空のときは空のリストファイルを作成する' do
      path = create_segment_list_file([], @dir)

      expect(File.read(path)).to eq('')
    end
  end

  describe '#download_segments' do
    let(:urls) { (1..5).map { |i| "https://example.com/seg#{i}.aac" } }

    def stub_segments(responses)
      allow(HTTP).to receive(:get) { |url| responses.fetch(url) }
    end

    it '全セグメントを保存し、URL順のファイルパス配列を返す' do
      stub_segments(urls.to_h { |url| [url, http_response(body: "data of #{File.basename(url)}")] })

      paths = download_segments(urls, @dir)

      expect(paths).to eq(urls.map { |url| "#{@dir}/#{File.basename(url)}" })
      paths.each { |path| expect(File.read(path)).to eq("data of #{File.basename(path)}") }
    end

    it 'ブロックを渡すと、変換後のデータを保存する（復号など）' do
      stub_segments(urls.to_h { |url| [url, http_response(body: 'encrypted')] })

      paths = download_segments(urls, @dir, &:reverse)

      expect(paths.size).to eq(urls.size)
      paths.each { |path| expect(File.read(path)).to eq('detpyrcne') }
    end

    it '失敗したセグメントは結果から除外し、失敗件数を警告する' do
      responses = urls.to_h { |url| [url, http_response(body: 'data')] }
      responses[urls[1]] = failed_response
      stub_segments(responses)

      paths = download_segments(urls, @dir)

      expect(paths).to eq((urls - [urls[1]]).map { |url| "#{@dir}/#{File.basename(url)}" })
      expect(File.exist?("#{@dir}/seg2.aac")).to be(false)
      expect(LOGGER).to have_received(:warn).with('1 segment(s) failed to download')
    end

    it 'URLが空のとき空配列を返す' do
      expect(download_segments([], @dir)).to eq([])
    end
  end
end
