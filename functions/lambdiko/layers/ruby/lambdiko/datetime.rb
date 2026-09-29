require 'date'
require 'time'

# 日時・ファイル名処理

WDAY_JA = %w[日 月 火 水 木 金 土].freeze

# YYYYMMDDHHMMSS 形式の文字列を Time に変換
def to_time(time_str)
  Time.strptime(time_str, '%Y%m%d%H%M%S')
end

# ファイル名に使用できない文字を _ に置換
def sanitize_filename(filename)
  filename.to_s.gsub(%r{[/\\:*?"<>|]}, '_')
end

# 放送日時表記（24時間制）
# to_str を省略した場合、通知用表記は開始時刻のみ
def format_airtime(ft_str, to_str = nil)
  ft = to_time(ft_str)
  date = ft.to_date

  ft_hhmm = ft.strftime('%H:%M')
  time_range = to_str ? "#{ft_hhmm}-#{to_time(to_str).strftime('%H:%M')}" : ft_hhmm

  {
    file_name: "#{date.strftime('%Y%m%d')}#{ft.strftime('%H%M')}",
    notify: "#{date.strftime('%Y-%m-%d')}（#{WDAY_JA[date.wday]}）#{time_range}"
  }
end

# 放送日時表記（radiko 用 29時間制）
def format_airtime_radiko(ft_str, to_str)
  ft = to_time(ft_str)
  to = to_time(to_str)

  date = ft.to_date
  ft_hour = ft.hour
  to_hour = to.hour

  # 放送中に日付を跨ぐ番組
  # 終了時刻のみ29時間制表記
  to_hour += 24 if to.hour < ft.hour

  # 深夜0〜4時台に開始する番組
  if ft.hour < 5
    # 放送日は前日
    date -= 1
    # 開始時刻・終了時刻を29時間制表記
    ft_hour += 24
    to_hour += 24
  end

  ft_hh = ft_hour.to_s.rjust(2, '0')
  ft_mm = ft.strftime('%M')
  to_hh = to_hour.to_s.rjust(2, '0')
  to_mm = to.strftime('%M')

  {
    file_name: "#{date.strftime('%Y%m%d')}#{ft_hh}#{ft_mm}",
    notify: "#{date.strftime('%Y-%m-%d')}（#{WDAY_JA[date.wday]}）#{ft_hh}:#{ft_mm}-#{to_hh}:#{to_mm}"
  }
end
