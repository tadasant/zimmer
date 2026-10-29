# frozen_string_literal: true

module LiveConversations
  # What the iOS app reports about its Live voice calls, put on the shipped log
  # stream: one structured OTLP record per event, under the instrumentation
  # scope `ios.live`, through the same exporter that ships Zimmer's own
  # WARN/ERROR lines to VictoriaLogs (config/initializers/otel_logs_exporter.rb).
  #
  # A voice call runs between the phone and OpenAI, and the car cannot be
  # tested from CI, so this is how a failure in the car is read afterwards: a
  # time-ordered trace of the call — connecting, the audio session and route,
  # turn detection as OpenAI applied it, speech starting and stopping, the
  # timings, the cues the app played, and every error — keyed by `call_id` and
  # ordered by `seq`.
  #
  # How much is kept is LiveSetting `voice_telemetry`, a threshold: `debug`
  # keeps everything, `info` milestones and problems, `warn` problems, `off`
  # nothing. The app filters by it before it builds an event, and this
  # filters again, so a setting turned down applies from the app's next batch
  # even when the app is still running on the level it read at call start. An
  # `error` event passes every level but `off`.
  #
  # Severity on the shipped record is the event's level, except that an `error`
  # ships as WARN with `level=error`: an ERROR record pages #alerts, and a car
  # losing signal on a drive is not something to page about. Nothing here is a
  # transcript: the app sends names, counts, timings and settings, and every
  # value is squished and truncated so a client cannot forge a log line.
  class Telemetry
    SCOPE = "ios.live"
    LEVELS = %w[debug info warn error].freeze
    SEVERITY = { "debug" => "DEBUG", "info" => "INFO", "warn" => "WARN", "error" => "WARN" }.freeze

    MAX_EVENTS = 100
    MAX_FIELDS = 40
    MAX_VALUE_CHARS = 300
    NAME = /\A[a-z][a-z0-9_.]{0,63}\z/
    KEY = /\A[a-z][a-z0-9_]{0,47}\z/
    # Set on every record from the event and the batch; a field by the same
    # name is dropped rather than allowed to overwrite one.
    RESERVED = %w[event level seq call_id conversation_id mono_ms surface app_version app_build os device dropped].freeze

    Result = Data.define(:accepted, :filtered, :threshold)

    # The lowest level kept, or nil when telemetry is off.
    def self.threshold(setting = LiveSetting.current)
      level = setting.effective(:voice_telemetry).to_s
      LEVELS.include?(level) ? level : nil
    end

    def initialize(exporter: OtelLogsExporter.instance, setting: LiveSetting.current)
      @exporter = exporter
      @threshold = self.class.threshold(setting)
    end

    # `batch`: { "client" => {app_version, app_build, os, device, surface}, "dropped" => n,
    # "events" => [{seq, name, level, at, mono_ms, call_id, conversation_id, fields}] }
    def ingest(batch)
      batch = batch.to_h
      client = (batch["client"] || {}).to_h
      events = Array(batch["events"]).first(MAX_EVENTS)
      envelope = {
        "surface" => text(client["surface"], 20),
        "app_version" => text(client["app_version"], 40),
        "app_build" => text(client["app_build"], 40),
        "os" => text(client["os"], 60),
        "device" => text(client["device"], 60)
      }
      dropped = batch["dropped"].to_i
      envelope["dropped"] = dropped if dropped.positive?

      kept = events.filter_map { |event| record(event.to_h, envelope) }
      kept.each { |record| @exporter&.enqueue(record) }
      Rails.logger.info(
        "[ios.live] #{kept.size} of #{events.size} call events kept (threshold #{@threshold || 'off'})" \
        "#{" — the app dropped #{dropped} before sending" if dropped.positive?}"
      )
      Result.new(accepted: kept.size, filtered: events.size - kept.size, threshold: @threshold || "off")
    end

    private

    def record(event, envelope)
      name = event["name"].to_s
      level = event["level"].to_s
      return nil unless name.match?(NAME) && LEVELS.include?(level) && kept?(level)

      call_id = text(event["call_id"], 64)
      seq = event["seq"].to_i
      attributes = envelope.merge(
        "event" => name, "level" => level, "seq" => seq, "call_id" => call_id,
        "conversation_id" => (event["conversation_id"].to_i if event["conversation_id"].present?),
        "mono_ms" => (event["mono_ms"].to_i if event["mono_ms"].present?)
      )
      extra = fields(event["fields"])
      attributes.merge!(extra)
      summary = extra.sort.map { |key, value| "#{key}=#{value}" }.join(" ")
      {
        timestamp: timestamp(event["at"]),
        severity: SEVERITY.fetch(level),
        scope: SCOPE,
        body: "[ios.live] #{name}#{" call=#{call_id}" if call_id} seq=#{seq}#{" #{summary}" if summary.present?}",
        attributes: attributes.compact
      }
    end

    def kept?(level)
      @threshold && LEVELS.index(level) >= LEVELS.index(@threshold)
    end

    def fields(raw)
      return {} unless raw.respond_to?(:to_h)

      raw.to_h.first(MAX_FIELDS).each_with_object({}) do |(key, value), kept|
        key = key.to_s
        next unless key.match?(KEY) && !RESERVED.include?(key)

        kept[key] = case value
        when Integer, Float, TrueClass, FalseClass then value
        when nil then nil
        when Hash, Array then text(value.to_json, MAX_VALUE_CHARS)
        else text(value, MAX_VALUE_CHARS)
        end
      end.compact
    end

    # The phone's wall clock, so a trace reads in the order it happened there;
    # the server's when the phone sent none or nonsense.
    def timestamp(value)
      Time.iso8601(value.to_s).to_f
    rescue ArgumentError
      Time.now.to_f
    end

    # Squished, so a newline in a client-sent value cannot forge a second line.
    def text(value, limit)
      value.to_s.squish.truncate(limit).presence
    end
  end
end
