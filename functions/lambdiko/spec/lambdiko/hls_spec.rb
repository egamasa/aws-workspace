require 'spec_helper'
require 'openssl'
require 'lambdiko/hls'

RSpec.describe 'Lambdiko::HLS' do
  describe '#parse_hls_master_playlist' do
    let(:master_playlist) { <<~M3U8 }
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=128000,CODECS="mp4a.40.2"
        https://example.com/128k/index.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=64000,CODECS="mp4a.40.2"
        https://example.com/64k/index.m3u8
      M3U8

    it '#EXT-X-STREAM-INF の次行をバリアントプレイリストURLとして抽出する' do
      expect(parse_hls_master_playlist(master_playlist)).to eq(
        %w[https://example.com/128k/index.m3u8 https://example.com/64k/index.m3u8]
      )
    end

    it '空行を挟んでいても次の行をURLとして抽出する' do
      playlist = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=128000\n\nhttps://example.com/index.m3u8\n"

      expect(parse_hls_master_playlist(playlist)).to eq(%w[https://example.com/index.m3u8])
    end

    it '#EXT-X-STREAM-INF がなければ空配列を返す' do
      expect(parse_hls_master_playlist("#EXTM3U\nsegment.aac\n")).to eq([])
    end

    it 'nil や空文字を渡すと空配列を返す' do
      expect(parse_hls_master_playlist(nil)).to eq([])
      expect(parse_hls_master_playlist('')).to eq([])
    end

    context 'lowest_bandwidth_only: true のとき' do
      it 'BANDWIDTH が最小のバリアントURLだけを配列で返す' do
        expect(parse_hls_master_playlist(master_playlist, lowest_bandwidth_only: true)).to eq(
          %w[https://example.com/64k/index.m3u8]
        )
      end

      it 'BANDWIDTH が同値なら先に記載されたものを返す' do
        playlist = <<~M3U8
          #EXT-X-STREAM-INF:BANDWIDTH=1000
          https://example.com/a.m3u8
          #EXT-X-STREAM-INF:BANDWIDTH=1000
          https://example.com/b.m3u8
        M3U8

        expect(parse_hls_master_playlist(playlist, lowest_bandwidth_only: true)).to eq(
          %w[https://example.com/a.m3u8]
        )
      end

      it 'バリアントが無い・nil なら空配列を返す' do
        expect(parse_hls_master_playlist("#EXTM3U\n", lowest_bandwidth_only: true)).to eq([])
        expect(parse_hls_master_playlist(nil, lowest_bandwidth_only: true)).to eq([])
      end
    end
  end

  describe '#parse_hls_playlist' do
    context '暗号化なしのプレイリストのとき' do
      let(:playlist) { <<~M3U8 }
          #EXTM3U
          #EXT-X-VERSION:3
          #EXT-X-TARGETDURATION:10
          #EXTINF:10.0,
          https://example.com/seg1.aac
          #EXTINF:10.0,

          https://example.com/seg2.aac
          #EXT-X-ENDLIST
        M3U8

      it 'コメント行と空行を除いたセグメントURLを順に返す' do
        result = parse_hls_playlist(playlist)

        expect(result[:segments]).to eq(
          %w[https://example.com/seg1.aac https://example.com/seg2.aac]
        )
      end

      it 'key_uri と iv は nil を返す' do
        result = parse_hls_playlist(playlist)

        expect(result[:key_uri]).to be_nil
        expect(result[:iv]).to be_nil
      end
    end

    context '相対パスのセグメントを含むとき' do
      let(:playlist) { "#EXTM3U\nseg1.aac\nhttps://cdn.example.com/seg2.aac\n" }

      it 'base_url を指定すると相対パスのみ base_url を付与する' do
        result = parse_hls_playlist(playlist, 'https://example.com/path/')

        expect(result[:segments]).to eq(
          %w[https://example.com/path/seg1.aac https://cdn.example.com/seg2.aac]
        )
      end

      it 'http:// で始まるURLも絶対URLとして扱う' do
        result = parse_hls_playlist("http://example.com/seg.aac\n", 'https://base/')

        expect(result[:segments]).to eq(%w[http://example.com/seg.aac])
      end
    end

    context 'AES-128 で暗号化されたプレイリストのとき' do
      let(:iv_hex) { '00112233445566778899AABBCCDDEEFF' }
      let(:playlist) { <<~M3U8 }
          #EXTM3U
          #EXT-X-KEY:METHOD=AES-128,URI="https://example.com/key.bin",IV=0x#{iv_hex}
          #EXTINF:10.0,
          https://example.com/seg1.aac
        M3U8

      it 'key_uri を抽出する' do
        expect(parse_hls_playlist(playlist)[:key_uri]).to eq('https://example.com/key.bin')
      end

      it 'iv を 16 バイトのバイナリとして返す' do
        iv = parse_hls_playlist(playlist)[:iv]

        expect(iv.bytesize).to eq(16)
        expect(iv.unpack1('H*')).to eq(iv_hex.downcase)
      end

      it '#EXT-X-KEY 行はセグメントに含めない' do
        expect(parse_hls_playlist(playlist)[:segments]).to eq(%w[https://example.com/seg1.aac])
      end

      it 'IV の指定がなければ key_uri のみ返し iv は nil になる' do
        playlist = %(#EXT-X-KEY:METHOD=AES-128,URI="https://example.com/key.bin"\nseg.aac\n)
        result = parse_hls_playlist(playlist)

        expect(result[:key_uri]).to eq('https://example.com/key.bin')
        expect(result[:iv]).to be_nil
      end
    end

    it 'nil や空文字を渡すとセグメントなしの結果を返す' do
      expect(parse_hls_playlist(nil)).to eq(segments: [], key_uri: nil, iv: nil)
      expect(parse_hls_playlist('')).to eq(segments: [], key_uri: nil, iv: nil)
    end
  end

  describe '#decrypt_aes128' do
    let(:key) { '0123456789abcdef' }
    let(:iv) { 'fedcba9876543210' }
    let(:plain_data) { 'segment data' * 100 }
    let(:encrypted_data) do
      cipher = OpenSSL::Cipher.new('aes-128-cbc')
      cipher.encrypt
      cipher.key = key
      cipher.iv = iv
      cipher.update(plain_data) + cipher.final
    end

    it 'AES-128-CBC で暗号化されたデータを復号する' do
      expect(decrypt_aes128(encrypted_data, key, iv)).to eq(plain_data)
    end

    it '異なるキーでは復号できず例外を発生させる' do
      expect { decrypt_aes128(encrypted_data, 'ffffffffffffffff', iv) }.to raise_error(
        OpenSSL::Cipher::CipherError
      )
    end
  end
end
