require 'openssl'

# HLS プレイリスト解析・セグメント復号

# マスタープレイリストからバリアントプレイリストURLを抽出
# #EXT-X-STREAM-INF の次行をURLとして扱う
def parse_hls_master_playlist(playlist)
  lines = playlist.to_s.lines.map(&:strip).reject(&:empty?)

  lines.each_cons(2).filter_map do |line, next_line|
    next_line if line.start_with?('#EXT-X-STREAM-INF:')
  end
end

# メディアプレイリストからセグメントURL・複合キーURI・初期化ベクトルを抽出
# 相対パスのセグメントには base_url を付与する
# IV が指定されていない場合、iv は nil を返す
def parse_hls_playlist(playlist, base_url = nil)
  segments = []
  key_uri = nil
  iv = nil

  playlist.to_s.lines.each do |line|
    line = line.strip
    next if line.empty?

    if line.start_with?('#EXT-X-KEY')
      key_uri = line[/URI="(.*?)"/, 1]
      iv_hex = line[/IV=0x([0-9A-Fa-f]+)/i, 1]
      iv = [iv_hex].pack('H*') if iv_hex
    end

    next if line.start_with?('#')

    segments << (line.match?(%r{\Ahttps?://}) ? line : "#{base_url}#{line}")
  end

  { segments: segments, key_uri: key_uri, iv: iv }
end

# セグメント復号（AES-128-CBC）
def decrypt_aes128(data, key, iv)
  cipher = OpenSSL::Cipher.new('aes-128-cbc')
  cipher.decrypt
  cipher.key = key
  cipher.iv = iv
  cipher.update(data) + cipher.final
end
