require "test_helper"
require "mocha/minitest"

# Unit tests for the OTLP/HTTP logs exporter
# (config/initializers/otel_logs_exporter.rb) that ships Zimmer's ERROR signal to
# the shared obs stack. These exercise the real OtelLogsExporter without
# starting its background thread or hitting the network: an instance built with
# `.new` parses its endpoint and allocates the queue but does NOT spawn the
# exporter thread (that only happens in `#start`). So we can enqueue records and
# inspect the in-memory queue / private envelope builder directly. No mocks of
# internal code; the only thing not real is the network send, which we never
# trigger.
class OtelLogsExporterTest < ActiveSupport::TestCase
  def build_exporter
    OtelLogsExporter.new(endpoint: "https://obs.example.test/otel/v1/logs", token: "test-token")
  end

  def drain(exporter)
    queue = exporter.instance_variable_get(:@queue)
    records = []
    loop do
      records << queue.pop(true)
    rescue ThreadError
      break
    end
    records
  end

  # ---- Resource attributes (the Grafana selector contract) ----------------
  # The paused scaffold rules-ao-errors.yaml selects on:
  #   service.name:zimmer AND deployment.environment:<env>
  #   AND severity_text:ERROR
  # If any of these field names/values drift, the alert goes blind. Pin them.

  test "build_envelope sets service.name=zimmer and deployment.environment resource attributes" do
    exporter = build_exporter
    envelope = JSON.parse(exporter.send(:build_envelope, [ { severity: "ERROR", body: "x", attributes: {} } ]))

    attrs = envelope["resourceLogs"].first["resource"]["attributes"]
    service_name = attrs.find { |a| a["key"] == "service.name" }
    deployment_env = attrs.find { |a| a["key"] == "deployment.environment" }

    assert_equal "zimmer", service_name["value"]["stringValue"]
    # In the test environment Rails.env is "test"; the attribute is always
    # present and is "production"/"staging" in deployed environments.
    assert_equal Rails.env.to_s, deployment_env["value"]["stringValue"]
  end

  test "OTEL_SERVICE_NAME overrides the default service.name" do
    ENV["OTEL_SERVICE_NAME"] = "custom-ao"
    exporter = build_exporter
    envelope = JSON.parse(exporter.send(:build_envelope, [ { severity: "ERROR", body: "x", attributes: {} } ]))
    attrs = envelope["resourceLogs"].first["resource"]["attributes"]
    service_name = attrs.find { |a| a["key"] == "service.name" }
    assert_equal "custom-ao", service_name["value"]["stringValue"]
  ensure
    ENV.delete("OTEL_SERVICE_NAME")
  end

  test "ERROR records carry severityText=ERROR and severityNumber=17" do
    exporter = build_exporter
    envelope = JSON.parse(exporter.send(:build_envelope, [ { severity: "ERROR", body: "boom", attributes: {} } ]))
    record = envelope["resourceLogs"].first["scopeLogs"].first["logRecords"].first
    assert_equal "ERROR", record["severityText"]
    assert_equal 17, record["severityNumber"]
  end

  # ---- start! no-op behavior ----------------------------------------------

  test "start! is a no-op when env vars are unset" do
    OtelLogsExporter.remove_instance_variable(:@instance) if OtelLogsExporter.instance_variable_defined?(:@instance)
    original_endpoint = ENV.delete("OTEL_LOGS_EXPORTER_ENDPOINT")
    original_token = ENV.delete("OTEL_LOGS_EXPORTER_BEARER_TOKEN")

    assert_nil OtelLogsExporter.start!
    assert_nil OtelLogsExporter.instance
  ensure
    ENV["OTEL_LOGS_EXPORTER_ENDPOINT"] = original_endpoint if original_endpoint
    ENV["OTEL_LOGS_EXPORTER_BEARER_TOKEN"] = original_token if original_token
    OtelLogsExporter.remove_instance_variable(:@instance) if OtelLogsExporter.instance_variable_defined?(:@instance)
  end

  # ---- build_job_failure_record -------------------------------------------

  test "build_job_failure_record shapes an ERROR record with the activejob scope" do
    record = OtelLogsExporter.build_job_failure_record(
      job_class: "AgentSessionJob",
      queue: "default",
      job_id: "abc-123",
      executions: 1,
      exception_class: "RuntimeError",
      exception_message: "agent process died",
      timestamp: 1_700_000_000.0
    )

    assert_equal "ERROR", record[:severity]
    assert_equal "rails.activejob", record[:scope]
    assert_equal 1_700_000_000.0, record[:timestamp]
    assert_includes record[:body], "AgentSessionJob"
    assert_includes record[:body], "RuntimeError"
    assert_includes record[:body], "agent process died"

    attrs = record[:attributes]
    assert_equal "AgentSessionJob", attrs["job_class"]
    assert_equal "default", attrs["queue"]
    assert_equal "abc-123", attrs["job_id"]
    assert_equal 1, attrs["executions"]
    assert_equal "RuntimeError", attrs["exception_class"]
    assert_equal "agent process died", attrs["exception_message"]
  end

  test "build_job_failure_record truncates an oversized exception message" do
    long_message = "x" * (OtelLogsExporter::MAX_BODY_CHARS + 500)
    record = OtelLogsExporter.build_job_failure_record(
      job_class: "SomeJob",
      queue: "default",
      job_id: "id",
      executions: 3,
      exception_class: "RuntimeError",
      exception_message: long_message
    )

    # Truncated message is capped at MAX_BODY_CHARS + the ellipsis marker.
    assert_equal OtelLogsExporter::MAX_BODY_CHARS + 1, record[:attributes]["exception_message"].length
    assert record[:attributes]["exception_message"].end_with?("…")
  end

  # ---- build_envelope (multi-scope grouping) ------------------------------

  test "build_envelope groups records into separate scopeLogs by scope" do
    exporter = build_exporter
    records = [
      { timestamp: 1.0, severity: "ERROR", body: "logger err", attributes: {} },                  # default rails.logger
      { timestamp: 2.0, severity: "ERROR", scope: "rails.activejob", body: "job failed", attributes: { "job_class" => "X" } },
      { timestamp: 3.0, severity: "WARN", scope: "rails.logger", body: "heads up", attributes: {} }
    ]

    envelope = JSON.parse(exporter.send(:build_envelope, records))
    scope_logs = envelope["resourceLogs"].first["scopeLogs"]
    scopes = scope_logs.map { |sl| sl["scope"]["name"] }

    assert_equal [ "rails.logger", "rails.activejob" ].sort, scopes.sort

    activejob_scope = scope_logs.find { |sl| sl["scope"]["name"] == "rails.activejob" }
    log_record = activejob_scope["logRecords"].first
    assert_equal "ERROR", log_record["severityText"]
    assert_equal 17, log_record["severityNumber"]
    assert_equal "job failed", log_record["body"]["stringValue"]
    job_class_attr = log_record["attributes"].find { |a| a["key"] == "job_class" }
    assert_equal "X", job_class_attr["value"]["stringValue"]
  end

  test "build_envelope survives invalid-UTF-8 bodies and attribute values" do
    exporter = build_exporter
    # A binary/ASCII-8BIT byte sequence that is NOT valid UTF-8. Before scrubbing
    # this raised JSON::GeneratorError on the export thread, dropping the whole
    # batch. Both the body and an attribute value carry the bad bytes.
    bad = "boom \xFF\xFE invalid".dup.force_encoding(Encoding::ASCII_8BIT)
    records = [
      { timestamp: 1.0, severity: "ERROR", scope: "rails.activejob", body: bad,
       attributes: { "exception_message" => bad } }
    ]

    json = nil
    assert_nothing_raised do
      json = exporter.send(:build_envelope, records)
    end

    # The envelope is valid JSON and the bad bytes were replaced, not dropped.
    envelope = JSON.parse(json)
    log_record = envelope["resourceLogs"].first["scopeLogs"].first["logRecords"].first
    assert_includes log_record["body"]["stringValue"], "boom"
    assert_includes log_record["body"]["stringValue"], "invalid"
    attr = log_record["attributes"].find { |a| a["key"] == "exception_message" }
    assert_includes attr["value"]["stringValue"], "boom"
  end

  test "build_envelope defaults records with no scope to rails.logger" do
    exporter = build_exporter
    envelope = JSON.parse(exporter.send(:build_envelope, [ { severity: "ERROR", body: "x", attributes: {} } ]))
    scope_logs = envelope["resourceLogs"].first["scopeLogs"]
    assert_equal 1, scope_logs.length
    assert_equal "rails.logger", scope_logs.first["scope"]["name"]
  end

  # ---- OtelLogAppender (logger-level catch-all) ---------------------------

  test "OtelLogAppender enqueues ERROR records under the rails.logger scope" do
    exporter = build_exporter
    appender = OtelLogAppender.new(exporter)

    appender.error("something broke")

    records = drain(exporter)
    assert_equal 1, records.length
    assert_equal "ERROR", records.first[:severity]
    assert_equal "rails.logger", records.first[:scope]
    assert_equal "something broke", records.first[:body]
  end

  test "OtelLogAppender enqueues WARN records" do
    exporter = build_exporter
    appender = OtelLogAppender.new(exporter)

    appender.warn("careful now")

    records = drain(exporter)
    assert_equal 1, records.length
    assert_equal "WARN", records.first[:severity]
    assert_equal "careful now", records.first[:body]
  end

  test "OtelLogAppender drops INFO and DEBUG records (level is WARN)" do
    exporter = build_exporter
    appender = OtelLogAppender.new(exporter)

    appender.info("just fyi")
    appender.debug("noisy detail")

    assert_empty drain(exporter)
  end

  test "OtelLogAppender supports the block form used by Rails.logger.error { ... }" do
    exporter = build_exporter
    appender = OtelLogAppender.new(exporter)

    appender.error { "computed message" }

    records = drain(exporter)
    assert_equal 1, records.length
    assert_equal "computed message", records.first[:body]
  end

  test "OtelLogAppender truncates oversized bodies" do
    exporter = build_exporter
    appender = OtelLogAppender.new(exporter)

    appender.error("y" * (OtelLogsExporter::MAX_BODY_CHARS + 1000))

    records = drain(exporter)
    assert_equal OtelLogsExporter::MAX_BODY_CHARS + 1, records.first[:body].length
    assert records.first[:body].end_with?("…")
  end

  test "OtelLogAppender never raises into application code when enqueue fails" do
    exporter = build_exporter
    appender = OtelLogAppender.new(exporter)
    # Simulate the queue being unavailable; the appender must swallow it.
    exporter.instance_variable_set(:@queue, nil)

    assert_nothing_raised do
      assert_equal true, appender.error("boom")
    end
  end

  # ---- deliver (the synchronous, inspectable export) ------------------------
  # The background run_loop can only ever warn to stderr, which makes a rejected
  # batch indistinguishable from an idle pipeline. `deliver` returns the outcome
  # so `bin/rails obs:smoke` can turn "no data in Grafana" into a status code.

  def stub_http_response(klass, code)
    response = klass.new("1.1", code, "")
    response.stubs(:body).returns("")
    Net::HTTP.any_instance.stubs(:request).returns(response)
  end

  test "deliver reports ok on a 2xx from the collector" do
    stub_http_response(Net::HTTPOK, "200")

    result = build_exporter.deliver([ { severity: "ERROR", body: "x", attributes: {} } ])

    assert result.ok
    assert_equal "200", result.code
    assert_nil result.error
  end

  test "deliver reports the status code on a rejected batch (e.g. a bad bearer token)" do
    stub_http_response(Net::HTTPUnauthorized, "401")

    result = build_exporter.deliver([ { severity: "ERROR", body: "x", attributes: {} } ])

    assert_not result.ok
    assert_equal "401", result.code
    assert_match(/HTTP 401/, result.to_s)
  end

  # The bearer token and the path ARE the contract with the obs ingest gateway: a
  # missing header is a 401 and a wrong path is a 404, and both present as silence.
  # Stubbing Net::HTTP#request wholesale would let a regression that dropped the
  # Authorization header pass every other test here, so capture the request itself.
  test "deliver sends the bearer token and posts to the endpoint's path" do
    captured = nil
    response = Net::HTTPOK.new("1.1", "200", "")
    response.stubs(:body).returns("")
    Net::HTTP.any_instance.stubs(:request).with { |req| captured = req }.returns(response)

    build_exporter.deliver([ { severity: "ERROR", body: "x", attributes: {} } ])

    assert_equal "Bearer test-token", captured["Authorization"]
    assert_equal "application/json", captured["Content-Type"]
    assert_equal "/otel/v1/logs", captured.path
    assert_equal "POST", captured.method
  end

  test "deliver captures a transport failure instead of raising" do
    Net::HTTP.any_instance.stubs(:request).raises(Errno::ECONNREFUSED, "connection refused")

    result = nil
    assert_nothing_raised { result = build_exporter.deliver([ { severity: "ERROR", body: "x", attributes: {} } ]) }

    assert_not result.ok
    assert_nil result.code
    assert_match(/Errno::ECONNREFUSED/, result.error)
  end

  test "send_batch swallows a rejected batch so the export thread survives it" do
    stub_http_response(Net::HTTPUnauthorized, "401")
    exporter = build_exporter

    assert_nothing_raised do
      capture_io { exporter.send(:send_batch, [ { severity: "ERROR", body: "x", attributes: {} } ]) }
    end
  end

  # ---- describe / pending (what `bin/rails obs:status` reads) ---------------

  test "describe reports where logs are shipped without leaking the bearer token" do
    exporter = build_exporter

    described = exporter.describe

    assert_equal "https://obs.example.test/otel/v1/logs", described[:endpoint]
    assert_equal "zimmer", described[:service_name]
    assert_equal Rails.env.to_s, described[:environment]
    # Not started, so no thread — the honest answer for a `.new` instance.
    assert_equal false, described[:running]
    assert_not_includes described.to_s, "test-token"
  end

  test "pending counts records the export thread has not yet picked up" do
    exporter = build_exporter

    assert_equal 0, exporter.pending
    exporter.enqueue({ severity: "ERROR", body: "x", attributes: {} })
    assert_equal 1, exporter.pending

    drain(exporter)
    assert_equal 0, exporter.pending
  end
end
