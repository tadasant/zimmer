# frozen_string_literal: true

# Live Mode's tunable settings and its guidance — one row for the deployment.
#
# Every column is nullable, and NULL means "the shipped default": the value Live
# Mode ran with before any of this was tunable. So a reset writes NULLs, and the
# row only ever records what somebody chose. FIELDS is the one list of what is
# tunable, read by the settings page, the REST API, the MCP tools and the live
# model's own `update_live_settings` function, so a field added here shows up on
# all four. Writes go through LiveConversations::SettingsUpdate, which validates
# them and records each in LiveSettingChange.
#
# Two paths read it on every turn:
#
# - the **text path** (Chat Completions, LiveConversations::TextReply) reads the
#   `text_*` fields before each request;
# - the **voice path** (Realtime, LiveConversations::RealtimeSession) reads the
#   `voice_*` fields when a call starts, and an open call is sent the ones a
#   Realtime session can change mid-call (`MID_CALL_KEYS`) as a `session.update`.
#
# `guidance` is appended to the system prompt on both paths (SystemPrompt).
#
# The `engine` fields pick what runs a voice call (LiveConversations::VoiceEngine)
# and cap what the experimental engines may spend (SpendGuard). The default
# engine is the voice path above; the others read the voice name, guidance and
# Claude model, and none of the Realtime knobs.
#
# What is offered is what the paths can actually use. The text path calls Chat
# Completions with function tools, which OpenAI's GPT-6 family accepts only from
# `gpt-6-luna` and `gpt-6-sol`, and only at `reasoning_effort: "none"` — so there
# is no text reasoning-effort setting, and the stronger GPT-6 models (Astra, 6.1
# Sol), which take tools only through the Responses API, are not offered. The
# ranges are narrower than the API's where an extreme would silence the agent:
# a VAD threshold of 1.0 never hears speech. The voice output cap's floor is the
# same idea with a price on it: the cap counts reasoning, speech and tool-call
# arguments together, and at 180 it cut 12 of a call's 13 responses short and
# every tool call on them.
#
# Turn detection decides which of its own knobs are used at all: RealtimeSession
# sends only the eagerness under `semantic_vad`, and only the threshold, padding
# and silence duration under `server_vad`. The others stay saved and do nothing.
# TURN_DETECTION_KNOBS is that split, `inactive_keys` is what follows from it for
# the row, and every surface that shows or writes a setting says so.
class LiveSetting < ApplicationRecord
  # Phase 1 of a two-phase drop (AGENTS.md "Dropping a column takes two
  # deploys"): `voice_claude_billing` chose how Claude's tokens were counted
  # when Claude ran on an API key. Claude runs on Zimmer's own subscription
  # credential now, so its use is always subscription-billed and the setting is
  # gone. A later PR drops the column.
  self.ignored_columns += [ "voice_claude_billing" ]

  Field = Data.define(:key, :path, :type, :label, :help, :options, :min, :max) do
    def text? = path == :text
    def voice? = path == :voice
    def engine? = path == :engine
    def enum? = type == :enum
    def numeric? = %i[float integer].include?(type)
    # The turn detection mode this field needs, or nil when it works in every mode.
    def applies_under = LiveSetting::TURN_DETECTION_KNOBS[key]

    def default = LiveSetting.default_for(key)

    def as_api_json
      {
        key: key.to_s, path: path.to_s, type: type.to_s, label: label, help: help,
        options: (LiveSetting.options_for(self).map { |value, text| { value: value, label: text } } if enum?),
        min: min, max: max, default: default, mid_call: (LiveSetting::MID_CALL_KEYS.include?(key) if voice?),
        applies_under: applies_under
      }.compact
    end
  end

  TEXT_MODELS = {
    "gpt-6-luna" => "gpt-6-luna — fastest (today's default)",
    "gpt-6-sol" => "gpt-6-sol — stronger, slower"
  }.freeze

  VOICE_MODELS = {
    "gpt-realtime-2.1-mini" => "gpt-realtime-2.1-mini — fast and cheap (today's default)",
    "gpt-realtime-2.1" => "gpt-realtime-2.1 — stronger reasoning and tool use, ~3× the audio price",
    "gpt-realtime-2" => "gpt-realtime-2 — the previous full model"
  }.freeze

  VOICES = %w[marin cedar alloy ash ballad coral echo sage shimmer verse].index_with(&:itself).freeze

  VOICE_REASONING_EFFORTS = {
    "minimal" => "minimal", "low" => "low", "medium" => "medium", "high" => "high", "xhigh" => "xhigh"
  }.freeze

  TURN_DETECTIONS = {
    "semantic_vad" => "Semantic — waits until you sound finished",
    "server_vad" => "Silence — answers after a fixed pause"
  }.freeze

  TURN_DETECTION_NAMES = { "semantic_vad" => "Semantic", "server_vad" => "Silence" }.freeze

  # The knobs RealtimeSession#turn_detection sends, and the mode it sends each in.
  TURN_DETECTION_KNOBS = {
    voice_vad_eagerness: "semantic_vad",
    voice_vad_threshold: "server_vad",
    voice_vad_prefix_padding_ms: "server_vad",
    voice_vad_silence_duration_ms: "server_vad"
  }.freeze

  EAGERNESS = {
    "auto" => "auto (medium)", "low" => "low — waits longest (up to 8s)",
    "medium" => "medium (up to 4s)", "high" => "high — answers soonest (up to 2s)"
  }.freeze

  LISTENING = {
    "always" => "Always — answers everything it hears (a private space, the car)",
    "wake_word" => "Wake word — answers only lines that say “Zimmer”",
    "dynamic" => "Dynamic — answers only lines it judges were said to it"
  }.freeze

  NOISE_REDUCTION = {
    "near_field" => "near field — headphones, a phone at your ear",
    "far_field" => "far field — laptop or car microphone"
  }.freeze

  TRANSCRIPTION_MODELS = {
    "gpt-4o-mini-transcribe" => "gpt-4o-mini-transcribe (today's default)",
    "gpt-4o-transcribe" => "gpt-4o-transcribe — more accurate"
  }.freeze

  # How much the iOS app reports about a voice call (LiveConversations::Telemetry):
  # a threshold, so each level keeps everything above it. An error is reported at
  # every level but `off`.
  TELEMETRY = {
    "debug" => "Verbose — every step of every call (turn detection, timings, cues)",
    "info" => "Milestones — connects, hang-ups, settings in use, timings, plus warnings and errors",
    "warn" => "Problems — warnings and errors only",
    "off" => "Off — the app reports nothing"
  }.freeze

  # Which engine runs a voice call (LiveConversations::VoiceEngine). The
  # experimental two are off until somebody picks one, and a call whose engine
  # cannot run — a key not set, a client that cannot speak it, a spend cap
  # reached — runs on `openai_realtime` instead and says why.
  VOICE_ENGINES = {
    "openai_realtime" => "OpenAI Realtime — today's engine (default)",
    "gpt_live_claude" => "GPT-Live front end, Claude reasoning — web only, experimental",
    "livekit_claude" => "LiveKit cascade with Claude — not built yet, falls back"
  }.freeze

  # The Claude model the experimental engines reason with.
  CLAUDE_MODELS = ModelCatalog::LIVE_CLAUDE_MODELS

  GUIDANCE_MAX_LENGTH = 8_000

  FIELDS = [
    Field.new(key: :text_model, path: :text, type: :enum, label: "Text model",
              help: "Answers typed turns, through Chat Completions with tools.",
              options: TEXT_MODELS, min: nil, max: nil),
    Field.new(key: :text_temperature, path: :text, type: :float, label: "Text temperature",
              help: "Higher is more varied. Blank leaves OpenAI's default (1.0).",
              options: nil, min: 0.0, max: 2.0),
    Field.new(key: :text_max_output_tokens, path: :text, type: :integer, label: "Text max output tokens",
              help: "A cap on one reply. Blank is no cap.",
              options: nil, min: 256, max: 128_000),
    Field.new(key: :voice_model, path: :voice, type: :enum, label: "Voice model",
              help: "The Realtime model. Takes effect on the next call.",
              options: VOICE_MODELS, min: nil, max: nil),
    Field.new(key: :voice_reasoning_effort, path: :voice, type: :enum, label: "Voice reasoning effort",
              help: "How much the voice model thinks before it speaks. Blank leaves the model's default. Takes effect on the next call.",
              options: VOICE_REASONING_EFFORTS, min: nil, max: nil),
    Field.new(key: :voice_name, path: :voice, type: :enum, label: "Voice",
              help: "Takes effect on the next call: OpenAI fixes a call's voice once it has spoken.",
              options: VOICES, min: nil, max: nil),
    Field.new(key: :voice_speed, path: :voice, type: :float, label: "Speaking speed",
              help: "A multiple of normal speed, 0.25 to 1.5. Changes mid-call, from the next reply.",
              options: nil, min: 0.25, max: 1.5),
    Field.new(key: :voice_max_output_tokens, path: :voice, type: :integer, label: "Voice max output tokens",
              help: "A cap on one voice response: its reasoning, speech and tool calls together. A low one cuts replies off mid-sentence. Blank is no cap.",
              options: nil, min: 1_024, max: 4_096),
    Field.new(key: :voice_listening, path: :voice, type: :enum, label: "Listening",
              help: "Which lines get an answer. The others are dropped: not answered, not kept in the call, not written to the thread. The microphone still streams to OpenAI in every mode.",
              options: LISTENING, min: nil, max: nil),
    Field.new(key: :voice_turn_detection, path: :voice, type: :enum, label: "Turn detection",
              help: "How the model decides you have finished talking.",
              options: TURN_DETECTIONS, min: nil, max: nil),
    Field.new(key: :voice_vad_eagerness, path: :voice, type: :enum, label: "Eagerness (semantic)",
              help: "How soon semantic turn detection answers.",
              options: EAGERNESS, min: nil, max: nil),
    Field.new(key: :voice_vad_threshold, path: :voice, type: :float, label: "Threshold (silence)",
              help: "How loud counts as speech, for silence turn detection. Higher ignores more background noise.",
              options: nil, min: 0.1, max: 0.95),
    Field.new(key: :voice_vad_prefix_padding_ms, path: :voice, type: :integer, label: "Prefix padding ms (silence)",
              help: "Audio kept from before speech was detected.",
              options: nil, min: 0, max: 1_000),
    Field.new(key: :voice_vad_silence_duration_ms, path: :voice, type: :integer, label: "Silence duration ms (silence)",
              help: "How long a pause ends your turn.",
              options: nil, min: 200, max: 3_000),
    Field.new(key: :voice_noise_reduction, path: :voice, type: :enum, label: "Noise reduction",
              help: "Filters the microphone before the model hears it. Blank is off.",
              options: NOISE_REDUCTION, min: nil, max: nil),
    Field.new(key: :voice_transcription_model, path: :voice, type: :enum, label: "Transcription model",
              help: "Writes down what you said, for the thread on the page.",
              options: TRANSCRIPTION_MODELS, min: nil, max: nil),
    Field.new(key: :voice_telemetry, path: :voice, type: :enum, label: "Call telemetry (iOS app)",
              help: "How much the phone and the car report about each voice call, to the shipped logs. Takes effect on the next call.",
              options: TELEMETRY, min: nil, max: nil),
    Field.new(key: :voice_engine, path: :engine, type: :enum, label: "Voice engine",
              help: "What runs a voice call. Takes effect on the next call. An engine that cannot run — a missing OpenAI key or Claude Code account, an app that cannot speak it, a spend cap reached — falls back to OpenAI Realtime, and the call says why.",
              options: VOICE_ENGINES, min: nil, max: nil),
    Field.new(key: :voice_claude_model, path: :engine, type: :enum, label: "Claude model",
              help: "The model the experimental engines reason and run tools with, on Zimmer's own Claude Code subscription — the account agent sessions run on, so its use counts against the same quota windows. No Anthropic key is needed. Takes effect on the next delegation.",
              options: CLAUDE_MODELS, min: nil, max: nil),
    Field.new(key: :voice_engine_conversation_cap_usd, path: :engine, type: :float, label: "Per-conversation cap (USD)",
              help: "The most an experimental engine may spend on one conversation. At 80% the call is warned; at the cap it ends and the next call runs on OpenAI Realtime.",
              options: nil, min: 0.1, max: 100.0),
    Field.new(key: :voice_engine_daily_cap_usd, path: :engine, type: :float, label: "Daily cap per engine (USD)",
              help: "The most each experimental engine may spend in a day (deployment time zone), across conversations. Same warning and fallback as the per-conversation cap.",
              options: nil, min: 0.5, max: 500.0)
  ].freeze

  FIELDS_BY_KEY = FIELDS.index_by(&:key).freeze
  KEYS = FIELDS.map(&:key).freeze

  # The voice fields a Realtime session accepts in a mid-call `session.update`.
  # The model and voice are fixed for a call's life, and reasoning effort is set
  # with the model; those three apply from the next call.
  MID_CALL_KEYS = %i[
    voice_speed voice_max_output_tokens voice_listening voice_turn_detection voice_vad_eagerness voice_vad_threshold
    voice_vad_prefix_padding_ms voice_vad_silence_duration_ms voice_noise_reduction voice_transcription_model
  ].freeze

  validate :only_one_row, on: :create

  # The defaults are today's behaviour. The three env variables predate this
  # table and still pick the shipped default, so a deployment that set one keeps
  # what it chose until somebody overrides it here.
  def self.default_for(key)
    case key.to_sym
    when :text_model then ENV.fetch("LIVE_MODE_MODEL", "").presence || "gpt-6-luna"
    when :voice_model then ENV.fetch("LIVE_VOICE_MODEL", "").presence || "gpt-realtime-2.1-mini"
    when :voice_name then ENV.fetch("LIVE_VOICE_VOICE", "").presence || "marin"
    when :voice_speed then 1.0
    when :voice_listening then "always"
    when :voice_turn_detection then "semantic_vad"
    when :voice_vad_eagerness then "auto"
    when :voice_vad_threshold then 0.5
    when :voice_vad_prefix_padding_ms then 300
    when :voice_vad_silence_duration_ms then 500
    when :voice_transcription_model then "gpt-4o-mini-transcribe"
    # Verbose: everything a call does is reported. Turned down on the Live
    # settings page, without a deploy.
    when :voice_telemetry then "debug"
    when :voice_engine then "openai_realtime"
    when :voice_claude_model then ModelCatalog::LIVE_CLAUDE_DEFAULT
    when :voice_engine_conversation_cap_usd then 2.0
    when :voice_engine_daily_cap_usd then 10.0
    end
  end

  # A model a deployment named in its env variable is a valid choice too, even
  # if it is not one of the listed ones — it is what that deployment already runs.
  def self.options_for(field)
    options = field.options || {}
    default = field.default
    return options if !field.enum? || default.nil? || options.key?(default)

    options.merge(default => "#{default} (this deployment's default)")
  end

  def self.field(key) = FIELDS_BY_KEY.fetch(key.to_sym)

  def self.turn_detection_name(mode) = TURN_DETECTION_NAMES.fetch(mode.to_s, mode.to_s)

  # One sentence on what a turn detection mode uses, for the page and the writers.
  def self.turn_detection_summary(mode, inactive: nil)
    name = turn_detection_name(mode)
    used, unused = FIELDS.select(&:applies_under).partition { |field| field.applies_under == mode }
    unused = unused.select { |field| inactive.include?(field.key) } if inactive
    "#{unused.map(&:label).to_sentence} #{unused.one? ? 'has' : 'have'} no effect under #{name} turn detection: " \
      "not sent to OpenAI. Under #{name}, use #{used.map(&:label).to_sentence}."
  end

  # The row, or a blank unsaved one before the first write — which answers every
  # read with the defaults. Never raises on a read path: a live turn must not die
  # because its settings could not be read.
  def self.current
    order(:id).first || new
  rescue ActiveRecord::ActiveRecordError => e
    Rails.logger.warn("[LiveSetting] could not read the settings row, using defaults: #{e.class}: #{e.message}")
    new
  end

  # The row for a write, created on first use.
  def self.editable
    order(:id).first || create!
  rescue ActiveRecord::RecordNotUnique
    order(:id).first!
  end

  # The value in force: the override, or the default.
  def effective(key)
    value = self[key.to_sym]
    value.nil? ? self.class.default_for(key) : value
  end

  def overridden?(key) = !self[key.to_sym].nil?

  # The settings saved but unused under the turn detection mode in force.
  def inactive_keys
    mode = effective(:voice_turn_detection)
    TURN_DETECTION_KNOBS.reject { |_key, needs| needs == mode }.keys
  end

  def guidance_text = guidance.to_s.strip

  # Every setting with its value, whether that is the default, and its choices
  # or range; then the guidance. What `get_live_settings` answers, for the live
  # model and for an agent through MCP alike.
  def describe
    lines = FIELDS.map do |field|
      choices = field.enum? ? "choices: #{self.class.options_for(field).keys.join(', ')}" : "range #{field.min}–#{field.max}"
      value = effective(field.key)
      unused = " — NO EFFECT now: used only under #{field.applies_under}" if inactive_keys.include?(field.key)
      "- #{field.key} = #{value.nil? ? 'not set' : value}#{' (default)' unless overridden?(field.key)} — #{field.label}; #{choices}#{unused}"
    end
    "Live settings:\n#{lines.join("\n")}\n\nLive mode guidance:\n#{guidance_text.presence || '(empty)'}"
  end

  def as_api_json
    {
      settings: KEYS.to_h { |key| [ key, effective(key) ] },
      overrides: KEYS.select { |key| overridden?(key) },
      inactive: inactive_keys,
      guidance: guidance_text,
      updated_at: (updated_at if persisted?),
      updated_by: updated_by,
      fields: FIELDS.map(&:as_api_json),
      guidance_max_length: GUIDANCE_MAX_LENGTH
    }
  end

  private

  def only_one_row
    errors.add(:base, "Live settings already exist") if self.class.exists?
  end
end
