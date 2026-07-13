# frozen_string_literal: true

require "test_helper"
require "rake"
require "mocha/minitest"

# Tests for lib/tasks/obs.rake — the diagnostics that exist because Zimmer's
# telemetry initializers are hard no-ops when unconfigured, so a MISCONFIGURED
# deployment is indistinguishable from a healthy one from inside the app.
#
# Both states are covered:
#   - disabled (what CI/dev/test see: no env vars, so no exporter)
#   - enabled  (an exporter instance installed by hand; the network is stubbed,
#              so no test ever talks to the real collector)
class ObsTasksTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    @had_instance = OtelLogsExporter.instance_variable_defined?(:@instance)
    @original_instance = OtelLogsExporter.instance_variable_get(:@instance) if @had_instance
  end

  teardown do
    Rake::Task.clear
    if @had_instance
      OtelLogsExporter.instance_variable_set(:@instance, @original_instance)
    elsif OtelLogsExporter.instance_variable_defined?(:@instance)
      OtelLogsExporter.remove_instance_variable(:@instance)
    end
  end

  def install_exporter
    exporter = OtelLogsExporter.new(endpoint: "https://obs.example.test/otel/v1/logs", token: "test-token")
    OtelLogsExporter.instance_variable_set(:@instance, exporter)
    exporter
  end

  def disable_exporter
    OtelLogsExporter.instance_variable_set(:@instance, nil)
  end

  def invoke(task)
    capture_io do
      Rake::Task[task].reenable
      Rake::Task[task].invoke
    end.first
  end

  # A hand-built Net::HTTPResponse has no socket, so #body would raise on read.
  # Stub it — the exporter reads `response.body` to surface the collector's
  # rejection text.
  def stub_collector(klass, code)
    response = klass.new("1.1", code, "")
    response.stubs(:body).returns("")
    Net::HTTP.any_instance.stubs(:request).returns(response)
  end

  # ---- obs:status ----------------------------------------------------------

  test "status reports OTLP logs OFF when the exporter is not running" do
    disable_exporter

    output = invoke("obs:status")

    assert_match(/\[OFF\] OTLP logs/, output)
    assert_match(/silent no-op/, output)
  end

  test "status reports the endpoint and the environment label when the exporter is live" do
    install_exporter

    output = invoke("obs:status")

    assert_match(/\[ON \] OTLP logs\s+-> https:\/\/obs\.example\.test\/otel\/v1\/logs/, output)
    assert_match(/deployment\.environment : #{Rails.env}/, output)
    # The token is the one thing that must never reach a deploy log or a PR.
    assert_not_includes output, "test-token"
  end

  test "status states plainly that metrics and traces are not shipped" do
    disable_exporter

    output = invoke("obs:status")

    # "No metrics in Grafana" is otherwise indistinguishable from a broken
    # metrics pipeline, and someone will go hunting for a bug that isn't there.
    assert_match(/\[--\] Metrics\s+-- not shipped by Zimmer/, output)
    assert_match(/\[--\] Traces\s+-- not shipped by Zimmer/, output)
  end

  # ---- obs:smoke -----------------------------------------------------------

  test "smoke skips the ingest probe and says so when the exporter is disabled" do
    disable_exporter

    output = invoke("obs:smoke")

    assert_match(/SKIPPED: exporter disabled/, output)
    assert_match(/marker: obs-smoke-[0-9a-f]{12}/, output)
  end

  test "smoke reports the collector's status code when it accepts the probe" do
    install_exporter
    stub_collector(Net::HTTPOK, "200")

    output = invoke("obs:smoke")

    assert_match(/✅ accepted \(HTTP 200\)/, output)
  end

  test "smoke names the likely cause when the collector rejects the probe" do
    install_exporter
    stub_collector(Net::HTTPUnauthorized, "401")

    output = invoke("obs:smoke")

    # The whole point: a 401 must read as "your bearer token is wrong", not as
    # silence.
    assert_match(/❌ rejected \(HTTP 401\)/, output)
    assert_match(/401 -> OTEL_LOGS_EXPORTER_BEARER_TOKEN does not match/, output)
  end

  test "smoke prints a LogsQL query scoped to this environment and the marker" do
    disable_exporter

    output = invoke("obs:smoke")

    marker = output[/obs-smoke-[0-9a-f]{12}/]
    assert_not_nil marker
    assert_match(/deployment\.environment:=#{Rails.env} "#{marker}"/, output)
  end
end
