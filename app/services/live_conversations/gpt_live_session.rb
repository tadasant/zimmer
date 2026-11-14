# frozen_string_literal: true

module LiveConversations
  # Starts a GPT-Live session for the `gpt_live_claude` engine.
  #
  # The browser creates its WebRTC offer (microphone track, `oai-events` data
  # channel) and posts it here; Rails sends it to OpenAI with the session
  # config — the model, the front end's instructions (SystemPrompt
  # .build_front_end), the voice, and client delegation — and hands the answer
  # back. As with Realtime, the key and the config stay on the server and the
  # audio goes between the browser and OpenAI.
  #
  # Client delegation means GPT-Live answers what it can and, for anything
  # else, emits `session.delegation.created`; the browser asks Rails to run it
  # (ClaudeDelegate) and appends the answer as commentary.
  class GptLiveSession
    MODEL = "gpt-live-1"
    SDP_MAX_BYTES = 64.kilobytes

    class Invalid < StandardError; end

    def self.start(conversation, sdp:, setting: LiveSetting.current, client: OpenaiClient.new)
      new(conversation, setting: setting, client: client).start(sdp)
    end

    def initialize(conversation, setting:, client:)
      @conversation = conversation
      @setting = setting
      @client = client
    end

    # @return [Hash] `{ session_id:, sdp:, model: }`
    def start(sdp)
      sdp = sdp.to_s
      raise Invalid, "sdp is required." if sdp.blank?
      raise Invalid, "sdp is too large." if sdp.bytesize > SDP_MAX_BYTES

      response = begin
        @client.create_live_session(body(sdp, voice: true))
      rescue OpenaiClient::Error => e
        raise unless [ 400, 422 ].include?(e.status) && @setting.overridden?(:voice_name)

        # The voice was chosen for Realtime and GPT-Live may not have it: start
        # on GPT-Live's own default rather than not at all.
        Rails.logger.warn("[LiveConversations::GptLiveSession] OpenAI refused the voice, retrying on the default: #{e.message.truncate(200)}")
        @client.create_live_session(body(sdp, voice: false))
      end
      answer = response.dig("transport", "sdp")
      raise OpenaiClient::Error, "OpenAI returned no SDP answer" if answer.blank?

      @conversation.update_columns(model: MODEL) if @conversation.model != MODEL
      { session_id: response.dig("session", "id"), sdp: answer, model: MODEL }
    end

    private

    def body(sdp, voice:)
      session = {
        model: MODEL,
        instructions: SystemPrompt.build_front_end(@conversation, setting: @setting),
        delegation: { type: "client" }
      }
      session[:audio] = { output: { voice: @setting.effective(:voice_name) } } if voice
      { session: session, transport: { type: "webrtc", sdp: sdp } }
    end
  end
end
