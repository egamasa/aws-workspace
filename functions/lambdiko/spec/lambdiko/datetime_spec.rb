require 'spec_helper'
require 'lambdiko/datetime'

RSpec.describe 'Lambdiko::Datetime' do
  describe '#to_time' do
    it 'YYYYMMDDHHMMSS 形式の文字列を Time に変換する' do
      time = to_time('20240407223015')

      expect(time).to be_a(Time)
      expect(time.strftime('%Y-%m-%d %H:%M:%S')).to eq('2024-04-07 22:30:15')
    end

    it '不正な文字列を渡すと ArgumentError を発生させる' do
      expect { to_time('invalid') }.to raise_error(ArgumentError)
    end
  end

  describe '#sanitize_filename' do
    it 'ファイル名に使用できない文字を _ に置換する' do
      expect(sanitize_filename('a/b\\c:d*e?f"g<h>i|j')).to eq('a_b_c_d_e_f_g_h_i_j')
    end

    it '日本語や記号（使用可能なもの）はそのまま残す' do
      expect(sanitize_filename('NISSAN あ、安部礼司 ～BEYOND THE AVERAGE～')).to eq(
        'NISSAN あ、安部礼司 ～BEYOND THE AVERAGE～'
      )
    end

    it 'nil を渡すと空文字を返す' do
      expect(sanitize_filename(nil)).to eq('')
    end
  end

  describe '#format_airtime' do
    it '開始・終了時刻を渡すと範囲表記で返す' do
      result = format_airtime('20240407220000', '20240407230000')

      expect(result[:file_name]).to eq('202404072200')
      expect(result[:notify]).to eq('2024-04-07（日）22:00-23:00')
    end

    it '終了時刻を省略すると通知用表記は開始時刻のみになる' do
      result = format_airtime('20240407220000')

      expect(result[:file_name]).to eq('202404072200')
      expect(result[:notify]).to eq('2024-04-07（日）22:00')
    end

    it '24時間制のまま表記し、日付を跨ぐ場合も開始日を放送日とする' do
      result = format_airtime('20240407235500', '20240408003000')

      expect(result[:file_name]).to eq('202404072355')
      expect(result[:notify]).to eq('2024-04-07（日）23:55-00:30')
    end

    it '曜日を日本語で表記する' do
      weekdays =
        %w[20240407 20240408 20240409 20240410 20240411 20240412 20240413].map do |date|
          format_airtime("#{date}120000")[:notify][/（(.)）/, 1]
        end

      expect(weekdays).to eq(%w[日 月 火 水 木 金 土])
    end
  end

  describe '#format_airtime_radiko' do
    it '通常の時間帯の番組は24時間制と同じ表記になる' do
      result = format_airtime_radiko('20240407220000', '20240407230000')

      expect(result[:file_name]).to eq('202404072200')
      expect(result[:notify]).to eq('2024-04-07（日）22:00-23:00')
    end

    it '5時台以降に開始する番組は翌日扱いにならない' do
      result = format_airtime_radiko('20240408050000', '20240408060000')

      expect(result[:file_name]).to eq('202404080500')
      expect(result[:notify]).to eq('2024-04-08（月）05:00-06:00')
    end

    it '放送中に日付を跨ぐ番組は終了時刻のみ29時間制で表記する' do
      result = format_airtime_radiko('20240407230000', '20240408000000')

      expect(result[:file_name]).to eq('202404072300')
      expect(result[:notify]).to eq('2024-04-07（日）23:00-24:00')
    end

    it '深夜0〜4時台に開始する番組は前日の放送として開始・終了時刻を29時間制で表記する' do
      result = format_airtime_radiko('20240408010000', '20240408013000')

      expect(result[:file_name]).to eq('202404072500')
      expect(result[:notify]).to eq('2024-04-07（日）25:00-25:30')
    end

    it '0時ちょうどに開始する番組は前日の24時として表記する' do
      result = format_airtime_radiko('20240408000000', '20240408003000')

      expect(result[:file_name]).to eq('202404072400')
      expect(result[:notify]).to eq('2024-04-07（日）24:00-24:30')
    end

    it '4時台に開始して5時台に終了する番組は終了時刻を29時として表記する' do
      result = format_airtime_radiko('20240408043000', '20240408050000')

      expect(result[:file_name]).to eq('202404072830')
      expect(result[:notify]).to eq('2024-04-07（日）28:30-29:00')
    end

    it '日付を跨いで終了する番組の終了時刻は24時以降で表記する' do
      result = format_airtime_radiko('20240407235500', '20240408003000')

      expect(result[:file_name]).to eq('202404072355')
      expect(result[:notify]).to eq('2024-04-07（日）23:55-24:30')
    end
  end
end
