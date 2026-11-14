# frozen_string_literal: true

module LiveConversations
  # Live Mode's Claude: the Messages API through the official `anthropic` gem,
  # for the experimental voice engines' reasoning (ClaudeDelegate).
  #
  # The key is `LIVE_ANTHROPIC_API_KEY`, resolved through SecretProviders like
  # OpenaiClient's, and deliberately not `ANTHROPIC_API_KEY`: store-resolved
  # variables can reach session environments, and that name is the one Claude
  # Code reads — a key set for Live must not change how agent sessions bill.
  # Unset, the engines that need it are unavailable and calls fall back to
  # OpenAI Realtime (VoiceEngine). `LIVE_ANTHROPIC_BASE_URL` points the client
  # elsewhere — a proxy, or a local stand-in when proving the flow end to end.
  #
  # Answers are plain string-keyed hashes, the wire shape, so nothing past this
  # class depends on the gem's model classes.
  class ClaudeClient
    API_KEY_VARIABLE = "LIVE_ANTHROPIC_API_KEY"
    DEFAULT_BASE_URL = "https://api.anthropic.com"
    # A delegation is waited on by a voice call; a slow one is worth less than
    # a quick "I could not get that" the person hears.
    TIMEOUT_SECONDS = 45
    MAX_RETRIES = 1

    class Error < StandardError; end
    class NotConfiguredError < Error; end

    def self.api_key(chain: SecretProviders.chain)
      chain.get(API_KEY_VARIABLE).presence
    rescue StandardError => e
      Rails.logger.warn("[claude] could not resolve #{API_KEY_VARIABLE}: #{e.class}")
      nil
    end

    def self.configured? = api_key.present?

    def self.base_url = ENV.fetch("LIVE_ANTHROPIC_BASE_URL", "").presence || DEFAULT_BASE_URL

    def initialize(api_key: self.class.api_key, base_url: self.class.base_url)
      raise NotConfiguredError, "#{API_KEY_VARIABLE} is not set" if api_key.blank?

      @client = Anthropic::Client.new(api_key: api_key, base_url: base_url, timeout: TIMEOUT_SECONDS, max_retries: MAX_RETRIES)
    end

    # @return [Hash] the message, string keys
    def create_message(**params)
      JSON.parse(@client.messages.create(**params).to_json)
    rescue Anthropic::Errors::APIError => e
      raise Error, "Claude: #{e.message.to_s.truncate(300)}"
    end
  end
end
