require 'discordrb/webhooks'
require 'json'
require 'logger'
require 'net/http'
require 'time'

LOGGER = Logger.new($stdout)

def get_webhook_url
  param_name = ENV['WEBHOOK_URL_PARAMETER_NAME']
  query = URI.encode_www_form(name: param_name, withDecryption: true)
  uri = URI.parse("http://localhost:2773/systemsmanager/parameters/get?#{query}")
  headers = { 'X-Aws-Parameters-Secrets-Token': ENV['AWS_SESSION_TOKEN'] }

  begin
    http = Net::HTTP.new(uri.host, uri.port)
    req = Net::HTTP::Get.new(uri.request_uri)
    req.initialize_http_header(headers)
    res = http.request(req)

    raise "[#{res.code}] #{res.body}" unless res.code == '200'
    return JSON.parse(res.body, symbolize_names: true).dig(:Parameter, :Value)
  rescue StandardError => e
    raise "Failed to get webhook URL: #{e.message}"
  end
end

def extract_notifications(event)
  notifications = []

  if event['Records']
    event['Records'].each do |record|
      notification = {
        subject: nil,
        message: nil,
        timestamp: record['Sns']['Timestamp'],
        data: nil
      }

      begin
        notification[:data] = JSON.parse(record['Sns']['Message'])
      rescue JSON::ParserError
        notification[:subject] = record['Sns']['Subject']
        notification[:message] = record['Sns']['Message']
      end

      notifications << notification
    end
  end

  return notifications
end

def get_embed_color(status)
  case status
  when 'OK'
    0x57f287 # Discord Green
  when 'INFO'
    0x5865f2 # Discord Blurple
  when 'WARN'
    0xfee75c # Discord Yellow
  when 'ERROR'
    0xed4245 # Discord Red
  else
    0x99aab5 # Discord Gray
  end
end

def build_embed(notification)
  embed = Discordrb::Webhooks::Embed.new

  title = notification[:subject]
  description = notification[:message]
  timestamp = notification[:timestamp]

  if notification[:data]
    title = [notification[:data]['service'], notification[:data]['title']].compact.join(' / ')
    description = notification[:data]['message']
    timestamp = notification[:data]['timestamp'] if notification[:data]['timestamp']
    embed.color = get_embed_color(notification[:data]['status'])

    if notification[:data]['fields']&.is_a?(Array)
      notification[:data]['fields'].each do |field|
        embed.add_field(name: field['name'], value: field['value'], inline: field['inline'])
      end
    end

    if notification[:data]['footer']
      embed.footer = Discordrb::Webhooks::EmbedFooter.new(text: notification[:data]['footer'])
    end
  end

  embed.title = title
  embed.description = description

  if timestamp
    begin
      embed.timestamp = Time.parse(timestamp)
    rescue ArgumentError
      embed.timestamp = Time.now
    end
  end

  return embed
end

def send_notifications(notifications)
  webhook_url = get_webhook_url

  notifications.each do |notification|
    begin
      embed = build_embed(notification)
      discord_client = Discordrb::Webhooks::Client.new(url: webhook_url)
      discord_client.execute { |builder| builder << embed }
    rescue StandardError => e
      LOGGER.error("Failed to send notification: #{e.message}")
    end
  end
end

def main(event)
  notifications = extract_notifications(event)

  send_notifications(notifications) if notifications.any?
end

def lambda_handler(event:, context:)
  main(event)
end
