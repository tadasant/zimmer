# frozen_string_literal: true

require "test_helper"

class LiveConversations::TelemetryTest < ActiveSupport::TestCase
  class FakeExporter
    attr_reader :records
    attr_accessor :busy

    def initialize
      @records = []
      @busy = 0
    end

    def enqueue(record) = @records << record
    def pending = @busy + @records.size
  end

  CLIENT = { "surface" => "carplay", "app_version" => "1.5.0", "app_build" => "212", "os" => "iOS 26.4", "device" => "iPhone17,1" }.freeze

  def event(seq, name, level, fields = {})
    { "seq" => seq, "name" => name, "level" => level, "at" => "2026-10-29T14:00:0#{seq}.250Z", "mono_ms" => 1_000 + seq,
      "call_id" => "C-1", "conversation_id" => 42, "fields" => fields }
  end

  setup { @exporter = FakeExporter.new }

  def ingest(events, setting: LiveSetting.new, **batch)
    LiveConversations::Telemetry.new(exporter: @exporter, setting: setting).ingest({ "client" => CLIENT, "events" => events }.merge(batch.stringify_keys))
  end

  test "each event is one structured record on the ios.live scope, with the call, its order and the phone's clock" do
    result = ingest([ event(1, "vad.speech_stopped", "debug", "audio_end_ms" => 4_120, "turn_detection" => "semantic_vad") ])

    assert_equal 1, result.accepted
    record = @exporter.records.sole
    assert_equal "ios.live", record[:scope]
    assert_equal "DEBUG", record[:severity]
    assert_in_delta Time.iso8601("2026-10-29T14:00:01.250Z").to_f, record[:timestamp], 0.001
    assert_equal "[ios.live] vad.speech_stopped call=C-1 seq=1 audio_end_ms=4120 turn_detection=semantic_vad", record[:body]
    attributes = record[:attributes]
    assert_equal({ "event" => "vad.speech_stopped", "level" => "debug", "seq" => 1, "call_id" => "C-1", "conversation_id" => 42, "mono_ms" => 1_001 },
                 attributes.slice("event", "level", "seq", "call_id", "conversation_id", "mono_ms"))
    assert_equal "carplay", attributes["surface"]
    assert_equal "212", attributes["app_build"]
    assert_equal 4_120, attributes["audio_end_ms"]
  end

  test "the setting is a threshold: verbose by default, and an error passes every level but off" do
    events = [ event(1, "vad.speech_started", "debug"), event(2, "call.connected", "info"), event(3, "audio.interruption", "warn"), event(4, "call.failed", "error") ]

    assert_equal 4, ingest(events).accepted, "debug is the shipped default"
    { "info" => 3, "warn" => 2, "off" => 0 }.each do |level, kept|
      @exporter.records.clear
      result = ingest(events, setting: LiveSetting.new(voice_telemetry: level))
      assert_equal kept, result.accepted, level
      assert_equal 4 - kept, result.filtered, level
      assert_equal level, result.threshold
    end
  end

  test "an error ships as WARN, so a car losing signal never pages #alerts" do
    ingest([ event(1, "call.failed", "error", "reason" => "The call dropped") ])

    record = @exporter.records.sole
    assert_equal "WARN", record[:severity]
    assert_equal "error", record[:attributes]["level"]
  end

  test "what the client sends cannot forge a line, overwrite the envelope or grow without bound" do
    fields = { "reason" => "one\nWARN forged line", "seq" => 999, "call_id" => "X", "Bad Key" => 1, "nested" => { "a" => 1 }, "long" => "x" * 1_000 }
    ingest([ event(1, "call.failed", "error", fields), event(2, "Not A Name", "info"), event(3, "x", "loud") ])

    record = @exporter.records.sole
    assert_not_includes record[:body], "\n"
    assert_equal "one WARN forged line", record[:attributes]["reason"]
    assert_equal 1, record[:attributes]["seq"], "a field cannot overwrite the event's own"
    assert_equal "C-1", record[:attributes]["call_id"]
    assert_not record[:attributes].key?("Bad Key")
    assert_equal '{"a":1}', record[:attributes]["nested"]
    assert_operator record[:attributes]["long"].length, :<=, LiveConversations::Telemetry::MAX_VALUE_CHARS

    @exporter.records.clear
    many = (1..250).map { |seq| event(seq, "vad.speech_started", "debug") }
    assert_equal LiveConversations::Telemetry::MAX_EVENTS, ingest(many).accepted
  end

  test "the app's events never take more than half the export queue, so records that page still fit" do
    @exporter.busy = LiveConversations::Telemetry::MAX_QUEUE_SHARE - 1
    result = ingest([ event(1, "call.connected", "info"), event(2, "call.ended", "info") ])

    assert_equal 1, result.accepted
    assert_equal 1, result.shed
  end

  test "what the app had to drop before sending is on every record of the batch" do
    ingest([ event(1, "call.connected", "info") ], dropped: 17)

    assert_equal 17, @exporter.records.sole[:attributes]["dropped"]
  end

  test "with no exporter configured nothing is shipped and nothing raises" do
    result = LiveConversations::Telemetry.new(exporter: nil, setting: LiveSetting.new).ingest({ "events" => [ event(1, "call.connected", "info") ] })

    assert_equal 1, result.accepted
  end

  test "the records are what the OTLP exporter puts on the wire" do
    ingest([ event(1, "call.connected", "info", "connect_ms" => 812) ])
    exporter = OtelLogsExporter.new(endpoint: "https://obs.example/otel/v1/logs", token: "t")

    envelope = JSON.parse(exporter.send(:build_envelope, @exporter.records))
    scope_logs = envelope.dig("resourceLogs", 0, "scopeLogs").sole
    assert_equal "ios.live", scope_logs.dig("scope", "name")
    log = scope_logs["logRecords"].sole
    assert_equal "INFO", log["severityText"]
    attributes = log["attributes"].to_h { |a| [ a["key"], a["value"].values.first ] }
    assert_equal "call.connected", attributes["event"]
    assert_equal "812", attributes["connect_ms"]
  end
end
