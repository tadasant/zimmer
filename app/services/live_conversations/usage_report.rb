# frozen_string_literal: true

module LiveConversations
  # What a voice client reports about the cost and speed of its call, written
  # to the LiveUsageEvent ledger.
  #
  # Some spend is only visible to the client: a Realtime call's tokens arrive on
  # its data channel (`response.done`), a GPT-Live call's billed seconds end
  # with it. The client sends volumes — tokens, seconds, timings — and never
  # money: the vendor and model are decided here from what Zimmer already knows
  # about the conversation and settings, the numbers are clamped, and the price
  # is applied by LiveVoicePricing. Each event carries the client's own key, so
  # a retried batch counts once.
  class UsageReport
    MAX_EVENTS = 50
    MAX_TOKENS = 10_000_000
    MAX_SECONDS = 4.hours.to_i
    MAX_MS = 10.minutes.in_milliseconds
    KEY = /\A[A-Za-z0-9_.:\-]{1,100}\z/

    # The operations a client may report, and the engines each belongs to.
    CLIENT_OPERATIONS = {
      "voice_tokens" => %w[openai_realtime],
      "transcription" => %w[openai_realtime],
      "voice_session" => %w[gpt_live_claude],
      "turn_latency" => LiveUsageEvent::ENGINES,
      "call" => LiveUsageEvent::ENGINES
    }.freeze

    class Invalid < StandardError; end

    Result = Data.define(:recorded, :cost_usd)

    # @param model [String, nil] the Realtime model the client's call runs on,
    #   from its mint. Taken only when it is one the Live settings offer;
    #   otherwise the conversation's own model column.
    def self.call(conversation, events, setting: LiveSetting.current, model: nil) = new(conversation, setting: setting, model: model).call(events)

    def initialize(conversation, setting:, model: nil)
      @conversation = conversation
      @setting = setting
      @model = model.to_s if LiveSetting.options_for(LiveSetting.field(:voice_model)).key?(model.to_s)
    end

    def call(events)
      events = Array(events)
      raise Invalid, "events must be a list of at most #{MAX_EVENTS}." if events.size > MAX_EVENTS

      rows = events.map do |event|
        event = event.to_unsafe_h if event.respond_to?(:to_unsafe_h)
        raise Invalid, "each event must be an object." unless event.is_a?(Hash)

        attributes_for(event)
      end
      # A row already on the ledger under the same key is a retry: not counted again.
      recorded = rows.map { |row| LiveUsageEvent.record!(**row) }.select(&:previously_new_record?)
      Result.new(recorded: recorded.size, cost_usd: recorded.sum { |row| row.cost_usd.to_f })
    end

    private

    def attributes_for(event)
      event = event.stringify_keys
      operation = event["operation"].to_s
      engine = event["engine"].to_s
      allowed = CLIENT_OPERATIONS[operation]
      raise Invalid, "operation must be one of: #{CLIENT_OPERATIONS.keys.join(', ')}." unless allowed
      raise Invalid, "#{operation} is not reported for engine #{engine.inspect}." unless allowed.include?(engine)
      # GPT-Live's billed seconds come from the call that ran on it, never from
      # one Zimmer sent elsewhere.
      if operation == "voice_session" && @conversation.voice_engine != engine
        raise Invalid, "this conversation's call is not running on #{engine}."
      end

      key = event["key"].to_s
      raise Invalid, "each event needs a key of at most 100 letters, digits or _.:-" unless KEY.match?(key)

      {
        engine: engine, operation: operation, live_conversation: @conversation,
        mode: VoiceEngine.mode_for(engine, setting: @setting, voice_model: @model),
        idempotency_key: "client:#{@conversation.id}:#{key}",
        **vendor_and_model(operation),
        input_tokens: tokens(event["input_tokens"]), output_tokens: tokens(event["output_tokens"]),
        cache_read_tokens: tokens(event["cache_read_tokens"]),
        audio_input_tokens: tokens(event["audio_input_tokens"]), audio_output_tokens: tokens(event["audio_output_tokens"]),
        seconds: number(event["seconds"], MAX_SECONDS), count: 1,
        latency_ms: milliseconds(event["latency_ms"]), first_audio_ms: milliseconds(event["first_audio_ms"]),
        error: event["error"].presence&.to_s&.squish&.truncate(250),
        details: details(event["details"])
      }
    end

    def vendor_and_model(operation)
      case operation
      when "voice_tokens" then { vendor: "openai_realtime", model: @model || @conversation.model.presence || @setting.effective(:voice_model) }
      when "transcription" then { vendor: "openai_transcription", model: @setting.effective(:voice_transcription_model) }
      when "voice_session" then { vendor: "openai_live", model: GptLiveSession::MODEL }
      else { vendor: "zimmer", model: nil }
      end
    end

    def tokens(value) = number(value, MAX_TOKENS).to_i

    def milliseconds(value) = value.nil? || value == "" ? nil : number(value, MAX_MS).to_i

    def number(value, max)
      number = Float(value.to_s)
      number.finite? ? number.clamp(0, max) : 0
    rescue ArgumentError, TypeError
      0
    end

    # A few short scalar values, for reading a row back — never a transcript.
    def details(value)
      return {} unless value.is_a?(Hash) || value.respond_to?(:to_unsafe_h)

      hash = value.respond_to?(:to_unsafe_h) ? value.to_unsafe_h : value
      hash.first(10).to_h { |k, v| [ k.to_s.truncate(40), v.is_a?(Numeric) || v == true || v == false ? v : v.to_s.truncate(120) ] }
    end
  end
end
