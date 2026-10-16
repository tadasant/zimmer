# frozen_string_literal: true

require "net/http"

# The two OpenAI calls the live modes make, over plain Net::HTTP:
#
# - Chat Completions, for Live Mode's typed turns (run server-side, in a job).
# - Realtime client secrets, for Live Mode's voice: Rails mints a short-lived `ek_…`
#   secret carrying the whole session config, and the browser or phone opens the
#   audio connection to OpenAI with it. Audio never passes through Puma, and the
#   long-lived key never leaves the server.
#
# The key is `LIVE_OPENAI_API_KEY`, resolved through SecretProviders (Parameter
# Store, then Rails credentials, then ENV). Zimmer never writes it: the Live page
# says whether it is set and links the console that sets it. Deliberately not
# `OPENAI_API_KEY`: store-resolved variables can reach session environments, and
# that name is one Codex and Pi read on their own — a key set for Live must not
# quietly change how those sessions
# authenticate or bill. `LIVE_OPENAI_BASE_URL` points the client somewhere else — an
# OpenAI-compatible proxy, or a local stand-in when proving the flow end to end.
class OpenaiClient
  API_KEY_VARIABLE = "LIVE_OPENAI_API_KEY"
  DEFAULT_BASE_URL = "https://api.openai.com/v1"

  OPEN_TIMEOUT_SECONDS = 5
  READ_TIMEOUT_SECONDS = 60

  class Error < StandardError
    attr_reader :status

    def initialize(message, status: nil)
      super(message)
      @status = status
    end
  end

  class NotConfiguredError < Error; end

  def self.api_key(chain: SecretProviders.chain)
    chain.get(API_KEY_VARIABLE).presence
  rescue StandardError => e
    Rails.logger.warn("[openai] could not resolve #{API_KEY_VARIABLE}: #{e.class}")
    nil
  end

  def self.configured? = api_key.present?

  def self.base_url = ENV.fetch("LIVE_OPENAI_BASE_URL", "").presence || DEFAULT_BASE_URL

  def initialize(api_key: self.class.api_key, base_url: self.class.base_url, read_timeout: READ_TIMEOUT_SECONDS)
    raise NotConfiguredError, "#{API_KEY_VARIABLE} is not set" if api_key.blank?

    @api_key = api_key
    @base_url = base_url.chomp("/")
    @read_timeout = read_timeout
  end

  # @return [Hash] the parsed completion
  def chat_completion(body)
    post_json("/chat/completions", body)
  end

  # @return [Hash] `{ "value" => "ek_…", "expires_at" => …, "session" => {…} }`
  def create_realtime_client_secret(body)
    post_json("/realtime/client_secrets", body)
  end

  private

  def post_json(path, body)
    uri = URI("#{@base_url}#{path}")
    request = Net::HTTP::Post.new(uri)
    request["Authorization"] = "Bearer #{@api_key}"
    request["Content-Type"] = "application/json"
    request.body = JSON.generate(body)

    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
      open_timeout: OPEN_TIMEOUT_SECONDS, read_timeout: @read_timeout) do |http|
      http.request(request)
    end

    parsed = parse(response.body)
    return parsed if response.is_a?(Net::HTTPSuccess)

    raise Error.new("OpenAI answered #{response.code}: #{error_message(parsed, response)}", status: response.code.to_i)
  rescue Net::OpenTimeout, Net::ReadTimeout => e
    raise Error, "OpenAI did not answer in time (#{e.class.name.demodulize})"
  rescue SocketError, SystemCallError, OpenSSL::SSL::SSLError => e
    raise Error, "Could not reach OpenAI: #{e.message}"
  end

  def parse(body)
    JSON.parse(body.to_s)
  rescue JSON::ParserError
    {}
  end

  def error_message(parsed, response)
    message = parsed.dig("error", "message") if parsed.is_a?(Hash)
    (message.presence || response.message.to_s).truncate(500)
  end
end
