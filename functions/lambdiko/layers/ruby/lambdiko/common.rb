# 文字列処理

# HTMLタグを除去し、連続する空白を1つにまとめる
def remove_html_tags(text)
  text.to_s.gsub(%r{</?[^>]+?>}, '').gsub(/\s+/, ' ').strip
end

# 全角英数字・全角スペースを半角に変換
def zenkaku_to_hankaku(text)
  text.to_s.tr('Ａ-Ｚａ-ｚ０-９　', 'A-Za-z0-9 ')
end
