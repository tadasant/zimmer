# frozen_string_literal: true

module LiveConversations
  # Mints what a Live Voice client needs to open its own audio connection to
  # OpenAI: a short-lived client secret whose session config Rails decides —
  # model, instructions, tools, transcription, turn detection, voice — so the
  # client never holds the real key and never decides what the model is told.
  #
  # The client then speaks to OpenAI directly (WebRTC in the browser, a
  # WebSocket on the phone), relays each function call to Rails
  # (ToolBridge) and each finished transcript line (as a turn), and sends a
  # `session.update` with fresh tools when a call says the tool set changed.
  class RealtimeSession
    SECRET_TTL_SECONDS = 600
    TRANSCRIPTION_MODEL = "gpt-4o-mini-transcribe"
    DEFAULT_VOICE = "marin"

    def self.mint(conversation, client: OpenaiClient.new) = new(conversation, client: client).mint

    def initialize(conversation, client:)
      @conversation = conversation
      @client = client
    end

    # @return [Hash] what the client is handed
    def mint
      secret = @client.create_realtime_client_secret(
        expires_after: { anchor: "created_at", seconds: SECRET_TTL_SECONDS },
        session: session_config
      )
      value = secret["value"].presence || secret.dig("client_secret", "value")
      raise OpenaiClient::Error, "OpenAI returned no client secret" if value.blank?

      {
        client_secret: value,
        expires_at: secret["expires_at"] || secret.dig("client_secret", "expires_at"),
        model: @conversation.model,
        calls_url: "#{OpenaiClient.base_url}/realtime/calls",
        websocket_url: "#{OpenaiClient.base_url.sub(/\Ahttp/, 'ws')}/realtime?model=#{ERB::Util.url_encode(@conversation.model)}",
        tools: tools
      }
    end

    def session_config
      {
        type: "realtime",
        model: @conversation.model,
        instructions: SystemPrompt.build(@conversation, recap: true),
        tools: tools,
        tool_choice: "auto",
        audio: {
          input: {
            transcription: { model: TRANSCRIPTION_MODEL },
            turn_detection: { type: "semantic_vad", create_response: true, interrupt_response: true }
          },
          output: { voice: self.class.voice }
        }
      }
    end

    def self.voice = ENV.fetch("LIVE_VOICE_VOICE", "").presence || DEFAULT_VOICE

    private

    def tools = @tools ||= ToolBridge.new(@conversation).realtime_tools
  end
end
