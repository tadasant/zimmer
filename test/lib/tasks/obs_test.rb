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

  # Both env vars are stashed, not just the one under test: OTEL_SERVICE_VERSION
  # takes precedence over ZIMMER_GIT_SHA, so leaving it alone makes these fail on
  # any machine that happens to set it.
  def with_env(vars)
    original = vars.keys.to_h { |k| [ k, ENV.key?(k) ? ENV[k] : nil ] }
    vars.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    original.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  test "status reports the build identity every exported record carries" do
    with_env("ZIMMER_GIT_SHA" => "0123456789abcdef0123456789abcdef01234567", "OTEL_SERVICE_VERSION" => nil) do
      install_exporter

      output = invoke("obs:status")

      assert_match(/service\.version\s+: 0123456789abcdef0123456789abcdef01234567/, output)
      assert_match(/service\.instance\.id=\S+ \(this process\)/, output)
    end
  end

  # The exporter resolves its identity once, at construction. obs:status must
  # report what is actually being SHIPPED, so a variable that changed after boot
  # must not change the answer — that would reintroduce the guesswork the task
  # exists to remove.
  test "status reports the exporter's resolved version, not whatever ENV says now" do
    exporter = with_env("ZIMMER_GIT_SHA" => "sha-at-boot", "OTEL_SERVICE_VERSION" => nil) { install_exporter }
    assert_equal "sha-at-boot", exporter.describe[:service_version]

    output = with_env("ZIMMER_GIT_SHA" => "sha-changed-later") { invoke("obs:status") }

    assert_match(/service\.version\s+: sha-at-boot/, output)
  end

  # An image built outside release-image.yml/deploy-staging.yml ships records with
  # no service.version at all. Saying so here is the point of the task: from inside
  # Grafana a missing attribute is indistinguishable from a broken pipeline.
  test "status says why service.version is missing when no build baked one in" do
    with_env("ZIMMER_GIT_SHA" => nil, "OTEL_SERVICE_VERSION" => nil) do
      install_exporter

      output = invoke("obs:status")

      assert_match(/service\.version\s+: \(unset --/, output)
      assert_match(/records ship without service\.version/, output)
    end
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
