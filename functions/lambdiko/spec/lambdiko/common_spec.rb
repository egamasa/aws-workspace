require 'spec_helper'
require 'lambdiko/common'

RSpec.describe 'Lambdiko::Common' do
  describe '#remove_html_tags' do
    it 'HTMLタグを除去する' do
      expect(remove_html_tags('<p>番組<b>説明</b></p>')).to eq('番組説明')
    end

    it '連続する空白・改行を1つの半角スペースにまとめ、前後の空白を除去する' do
      expect(remove_html_tags("  行1\n\n  行2\t行3  ")).to eq('行1 行2 行3')
    end

    it 'タグ除去後の空白もまとめる' do
      expect(remove_html_tags("<p>A</p>\n<p>B</p>")).to eq('A B')
    end

    it 'nil を渡すと空文字を返す' do
      expect(remove_html_tags(nil)).to eq('')
    end
  end

  describe '#zenkaku_to_hankaku' do
    it '全角英数字を半角に変換する' do
      expect(zenkaku_to_hankaku('ＡＢＣ ａｂｃ １２３')).to eq('ABC abc 123')
    end

    it '全角スペースを半角スペースに変換する' do
      expect(zenkaku_to_hankaku('第１回　放送')).to eq('第1回 放送')
    end

    it '日本語や半角文字はそのまま残す' do
      expect(zenkaku_to_hankaku('ラジオ英会話 abc')).to eq('ラジオ英会話 abc')
    end

    it 'nil を渡すと空文字を返す' do
      expect(zenkaku_to_hankaku(nil)).to eq('')
    end
  end
end
