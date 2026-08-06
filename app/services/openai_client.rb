require "net/http"
require "json"

# Thin Chat Completions client. Uses OPENAI_API_KEY (and optional OPENAI_MODEL).
class OpenaiClient
  class Error < StandardError; end
  class ConfigurationError < Error; end
  class ApiError < Error; end

  ENDPOINT = URI("https://api.openai.com/v1/chat/completions").freeze
  DEFAULT_MODEL = "gpt-4o-mini".freeze

  def self.chat(**kwargs)
    new.chat(**kwargs)
  end

  def initialize(api_key: ENV["OPENAI_API_KEY"], model: ENV.fetch("OPENAI_MODEL", DEFAULT_MODEL))
    @api_key = api_key.to_s.strip.presence
    @model = model.to_s.strip.presence || DEFAULT_MODEL
  end

  def configured?
    @api_key.present?
  end

  # messages: [{ role:, content: }, ...]
  # response_format: optional Hash (e.g. { type: "json_object" })
  def chat(messages:, temperature: 0.2, response_format: nil, model: nil)
    raise ConfigurationError, "OPENAI_API_KEY is not set" unless configured?

    body = {
      model: model.presence || @model,
      messages: messages,
      temperature: temperature
    }
    body[:response_format] = response_format if response_format.present?

    response = post_json(body)
    content = response.dig("choices", 0, "message", "content")
    raise ApiError, "OpenAI response missing content: #{response.inspect}" if content.blank?

    {
      content: content,
      model: response["model"],
      usage: response["usage"],
      raw: response
    }
  end

  private

  def post_json(payload)
    http = Net::HTTP.new(ENDPOINT.host, ENDPOINT.port)
    http.use_ssl = true
    http.open_timeout = 15
    http.read_timeout = 90

    request = Net::HTTP::Post.new(ENDPOINT)
    request["Authorization"] = "Bearer #{@api_key}"
    request["Content-Type"] = "application/json"
    request["Accept"] = "application/json"
    request.body = JSON.generate(payload)

    response = http.request(request)
    parsed = JSON.parse(response.body)

    unless response.is_a?(Net::HTTPSuccess)
      message = parsed.dig("error", "message") || response.body.to_s.truncate(300)
      raise ApiError, "OpenAI HTTP #{response.code}: #{message}"
    end

    parsed
  rescue JSON::ParserError, Timeout::Error, Errno::ECONNREFUSED, SocketError => e
    raise ApiError, e.message
  end
end
