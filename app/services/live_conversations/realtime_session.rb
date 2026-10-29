# frozen_string_literal: true

module LiveConversations
  # Mints what a voice client needs to open its own audio connection to
  # OpenAI: a short-lived client secret whose session config Rails decides —
  # model, instructions, tools, transcription, turn detection, voice — so the
  # client never holds the real key and never decides what the model is told.
  #
  # The client then speaks to OpenAI directly (WebRTC in the browser, a
  # WebSocket on the phone), relays each function call to Rails
  # (ToolBridge) and each finished transcript line (as a turn), and sends a
  # `session.update` with fresh tools when a call says the tool set changed.
  #
  # The session config comes from LiveSetting: the model, voice, speed, turn
  # detection and the rest are read when the secret is minted, and
  # #session_update is the subset an open call can change, which the client
  # sends whenever the settings or the guidance change mid-call.
  #
  # Which lines the call answers is Listening's: in a gated mode turn detection
  # neither starts a reply nor cuts one off, and the client asks for each reply
  # itself. `listening_modes` is whether this client can do that; a client that
  # cannot gets `always`, whatever the setting says.
  #
  # The instructions are SystemPrompt's for the spoken mode, with a recap of the
  # thread: the conversation may have been typed until a moment ago, and a new
  # Realtime session remembers nothing.
  class RealtimeSession
    SECRET_TTL_SECONDS = 600

    def self.mint(conversation, client: OpenaiClient.new, listening_modes: false)
      new(conversation, client: client, listening_modes: listening_modes).mint
    end

    def initialize(conversation, client: nil, setting: LiveSetting.current, listening_modes: false)
      @conversation = conversation
      @client = client
      @setting = setting
      @listening_modes = listening_modes
    end

    def listening = Listening.mode(@setting, capable: @listening_modes)

    # @return [Hash] what the client is handed
    def mint
      config = session_config
      warning = nil
      secret = begin
        create_secret(config)
      rescue OpenaiClient::Error => e
        raise unless refused_config?(e)

        # OpenAI refused the configured settings (a model this key cannot use, an
        # effort that model does not take): start the call on the defaults rather
        # than not at all, and say why.
        warning = "OpenAI refused the Live settings (#{e.message.truncate(200)}), so this call runs on the defaults. Change them on the Live settings page."
        Rails.logger.warn("[LiveConversations::RealtimeSession] #{warning}")
        # Listening and telemetry are Zimmer's, not OpenAI's: they stay as set.
        @setting = LiveSetting.new(guidance: @setting.guidance, voice_listening: @setting.voice_listening,
                                   voice_telemetry: @setting.voice_telemetry)
        config = session_config
        create_secret(config)
      end
      value = secret["value"].presence || secret.dig("client_secret", "value")
      raise OpenaiClient::Error, "OpenAI returned no client secret" if value.blank?

      model = config[:model]
      @conversation.update_columns(model: model) if @conversation.persisted? && @conversation.model != model
      {
        client_secret: value,
        expires_at: secret["expires_at"] || secret.dig("client_secret", "expires_at"),
        model: model,
        calls_url: "#{OpenaiClient.base_url}/realtime/calls",
        websocket_url: "#{OpenaiClient.base_url.sub(/\Ahttp/, 'ws')}/realtime?model=#{ERB::Util.url_encode(model)}",
        tools: tools,
        listening: listening,
        # How much the app reports about this call (Telemetry); the app keeps
        # it for the calls after, until the next secret says otherwise.
        telemetry: @setting.effective(:voice_telemetry),
        settings_warning: warning
      }.compact
    end

    def session_config
      config = {
        type: "realtime",
        model: @setting.effective(:voice_model),
        instructions: SystemPrompt.build(@conversation, recap: true, setting: @setting),
        tools: tools,
        tool_choice: "auto",
        audio: {
          input: input_audio.compact,
          output: { voice: @setting.effective(:voice_name), speed: @setting.effective(:voice_speed) }
        }
      }
      config[:max_output_tokens] = @setting.effective(:voice_max_output_tokens) if @setting.overridden?(:voice_max_output_tokens)
      effort = @setting.effective(:voice_reasoning_effort)
      config[:reasoning] = { effort: effort } if effort.present?
      config
    end

    # What an open call is sent when the settings or the guidance change: the
    # instructions and tools, and every setting a Realtime session takes mid-call
    # (LiveSetting::MID_CALL_KEYS). Never the model, voice or reasoning effort —
    # those are fixed for a call's life and apply from the next one.
    def session_update
      update = {
        type: "realtime",
        instructions: SystemPrompt.build(@conversation, recap: true, setting: @setting),
        tools: tools,
        audio: { input: input_audio, output: { speed: @setting.effective(:voice_speed) } }
      }
      update[:max_output_tokens] = @setting.overridden?(:voice_max_output_tokens) ? @setting.effective(:voice_max_output_tokens) : "inf"
      update
    end

    private

    # `noise_reduction: nil` turns it off, which a mid-call update has to say
    # out loud; a new call leaves it out (#session_config compacts it).
    def input_audio
      {
        transcription: { model: @setting.effective(:voice_transcription_model) },
        turn_detection: turn_detection,
        noise_reduction: (@setting.effective(:voice_noise_reduction).presence&.then { |type| { type: type } })
      }
    end

    def turn_detection
      answers_itself = !Listening.gated?(listening)
      if @setting.effective(:voice_turn_detection) == "server_vad"
        {
          type: "server_vad",
          threshold: @setting.effective(:voice_vad_threshold),
          prefix_padding_ms: @setting.effective(:voice_vad_prefix_padding_ms),
          silence_duration_ms: @setting.effective(:voice_vad_silence_duration_ms),
          create_response: answers_itself, interrupt_response: answers_itself
        }
      else
        { type: "semantic_vad", eagerness: @setting.effective(:voice_vad_eagerness), create_response: answers_itself, interrupt_response: answers_itself }
      end
    end

    def create_secret(config)
      client.create_realtime_client_secret(
        expires_after: { anchor: "created_at", seconds: SECRET_TTL_SECONDS },
        session: config
      )
    end

    def client = @client ||= OpenaiClient.new

    # A 4xx about the request, from a row that is not all defaults — the case a
    # retry on the defaults can fix. Anything else (the key, a 5xx, a timeout)
    # would fail the same way again.
    def refused_config?(error)
      [ 400, 404, 422 ].include?(error.status) && LiveSetting::KEYS.any? { |key| @setting.overridden?(key) }
    end

    def tools = @tools ||= ToolBridge.new(@conversation).realtime_tools
  end
end
