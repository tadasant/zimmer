# frozen_string_literal: true

module LiveConversations
  # Which engine runs a voice call: the LiveSetting `voice_engine`, unless it
  # cannot run, in which case the call runs on DEFAULT and says why.
  #
  # - `openai_realtime` — today's engine and the default. Rails mints a Realtime
  #   client secret; the client talks to OpenAI directly (RealtimeSession).
  # - `gpt_live_claude` — OpenAI's GPT-Live (`gpt-live-1`) as the full-duplex
  #   voice front end, with every tool call and anything that needs thought
  #   delegated to Claude, which runs Zimmer's tools (ClaudeDelegate). Rails
  #   starts the GPT-Live session with the browser's WebRTC offer
  #   (GptLiveSession); audio goes browser ⇄ OpenAI as today.
  # - `livekit_claude` — a LiveKit Agents cascade (speech-to-text → Claude →
  #   text-to-speech). Not built: it needs an agent worker deployed next to
  #   Zimmer, so it always falls back for now.
  #
  # An engine runs only when its keys are set, the client asking can speak it
  # (each client sends the engines it can run; one that sends none — the iOS
  # app today — runs only the default), and its spend is under the caps
  # (SpendGuard). Everything else falls back, so choosing an engine can never
  # leave Live Mode without a voice.
  class VoiceEngine
    DEFAULT = "openai_realtime"
    GPT_LIVE = "gpt_live_claude"
    LIVEKIT = "livekit_claude"
    KEYS = LiveSetting::VOICE_ENGINES.keys.freeze

    Resolution = Data.define(:engine, :requested, :fallback_reason, :warning) do
      def fallback? = fallback_reason.present?
      def default? = engine == DEFAULT

      def as_api_json = { engine: engine, requested: requested, fallback_reason: fallback_reason, warning: warning }.compact
    end

    # What stops an engine running anywhere, or nil when it can.
    def self.unavailable_reason(engine)
      case engine.to_s
      when DEFAULT then nil
      when GPT_LIVE
        missing = []
        missing << OpenaiClient::API_KEY_VARIABLE unless OpenaiClient.configured?
        missing << ClaudeClient::API_KEY_VARIABLE unless ClaudeClient.configured?
        "#{missing.join(' and ')} #{missing.one? ? 'is' : 'are'} not set" if missing.any?
      when LIVEKIT then "the LiveKit engine is not built yet: it needs an agent worker deployed next to Zimmer"
      else "#{engine.inspect} is not a voice engine"
      end
    end

    # The engine with the models it runs on, as a label: what /live/costs
    # compares. A call's mode is settled when it starts (on the conversation's
    # `voice_mode`), so a setting changed mid-call does not move its usage.
    # `voice_model` / `effort`: what a Realtime call was actually minted with,
    # which is not the settings when OpenAI refused them.
    def self.mode_for(engine, setting: LiveSetting.current, voice_model: nil, effort: :setting, claude_model: nil)
      case engine.to_s
      when DEFAULT
        effort = setting.effective(:voice_reasoning_effort) if effort == :setting
        effort = effort.presence
        [ voice_model.presence || setting.effective(:voice_model), ("effort #{effort}" if effort) ].compact.join(" · ")
      when GPT_LIVE then "#{GptLiveSession::MODEL} + #{claude_model.presence || setting.effective(:voice_claude_model)}"
      when LIVEKIT then "livekit + #{setting.effective(:voice_claude_model)}"
      else engine.to_s
      end
    end

    # Each engine with whether it can run, for the settings and costs pages.
    def self.statuses
      KEYS.map { |key| { engine: key, label: LiveSetting::VOICE_ENGINES[key], unavailable_reason: unavailable_reason(key) } }
    end

    # @param client_engines [Array<String>] the non-default engines the asking client can run
    # @return [Resolution]
    def self.resolve(conversation, setting: LiveSetting.current, client_engines: [])
      requested = setting.effective(:voice_engine).to_s
      return Resolution.new(engine: DEFAULT, requested: DEFAULT, fallback_reason: nil, warning: nil) if requested == DEFAULT

      reason = unavailable_reason(requested)
      reason ||= "this app cannot run #{requested} yet (only the web call dock can)" unless Array(client_engines).map(&:to_s).include?(requested)
      check = SpendGuard.check(engine: requested, conversation: conversation, setting: setting) if reason.nil?
      reason ||= check.reason
      return Resolution.new(engine: DEFAULT, requested: requested, fallback_reason: reason, warning: nil) if reason

      Resolution.new(engine: requested, requested: requested, fallback_reason: nil, warning: check.warning)
    end
  end
end
