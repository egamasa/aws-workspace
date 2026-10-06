require 'json'
require 'net/http'
require 'uri'

# 番組表 API 取得用 HTTP ヘルパー
module HttpHelper
  private

  def http_get_json(url, headers = {})
    uri = URI.parse(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')

    req = Net::HTTP::Get.new(uri.request_uri)
    headers.each { |key, value| req[key] = value }

    res = http.request(req)
    return JSON.parse(res.body) if res.is_a?(Net::HTTPSuccess)

    raise "Failed to fetch JSON: HTTP #{res.code} - #{url}"
  end
end
