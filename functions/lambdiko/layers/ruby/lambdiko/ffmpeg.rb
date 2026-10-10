require 'logger'
require 'open3'

LOGGER = Logger.new($stdout) unless defined?(LOGGER)

def run_ffmpeg(segment_list_file_path, output_file_path, metadata_options, artwork_option)
  cmd = [
    '/opt/bin/ffmpeg',
    '-hide_banner',
    '-y',
    '-safe',
    '0',
    '-f',
    'concat',
    '-i',
    segment_list_file_path
  ]

  # artwork_option は ['-i', 画像パス, ...出力オプション] の形式。
  # -map は全入力の後でないと指定できないため、-i の2要素だけを先に置く
  cmd.concat(artwork_option.first(2)) if artwork_option

  # 映像付きストリームでも常に音声のみを出力する（-map 1:v より前に置く）
  cmd.concat(%w[-map 0:a])

  cmd.concat(artwork_option.drop(2)) if artwork_option
  cmd.concat(metadata_options)
  cmd.concat(['-c', 'copy', '-bsf:a', 'aac_adtstoasc', output_file_path])

  _, stderr, status = Open3.capture3(*cmd)
  raise "FFmpeg failed: #{stderr}" unless status.success?
end

def probe_duration(file_path)
  cmd = [
    '/opt/bin/ffprobe',
    '-v',
    'error',
    '-show_entries',
    'format=duration',
    '-of',
    'default=noprint_wrappers=1:nokey=1',
    file_path
  ]
  out, _, status = Open3.capture3(*cmd)

  if status.success? && !out.strip.empty?
    total_sec = out.strip.to_f.round
    h, m, s = total_sec / 3600, (total_sec % 3600) / 60, total_sec % 60
    (h > 0 ? "#{h}h " : '') + "#{m}m #{s}s"
  else
    LOGGER.warn("ffprobe failed: #{out}")
    '-h --m --s'
  end
end
