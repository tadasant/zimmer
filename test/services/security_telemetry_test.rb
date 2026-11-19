# frozen_string_literal: true

require "test_helper"

class SecurityTelemetryTest < ActiveSupport::TestCase
  include SecurityTelemetryTestHelpers

  # Buckets are wall-clock; park mid-bucket so a burst never straddles a boundary.
  MID_BUCKET = Time.utc(2026, 11, 19, 12, 2, 30)

  setup do
    SecurityTelemetry.discard_pending!
    travel_to MID_BUCKET
  end
  teardown { travel_back }

  test "auth failures are counted by kind and reason, every label set present" do
    report = with_security_telemetry do
      3.times { SecurityTelemetry.record_auth_failure(:api_key, :unknown) }
      SecurityTelemetry.record_auth_failure("api_key", "missing")
      SecurityTelemetry.record_auth_failure(:webhook_github, :bad_signature)
    end

    assert_equal 3600, report[:window_seconds]
    assert_equal 4, report[:auth_failures_by_kind]["api_key"]
    assert_equal 1, report[:auth_failures_by_kind]["webhook_github"]
    assert_equal 0, report[:auth_failures_by_kind]["web_second_factor"], "a quiet kind is a zero, not absent"
    assert_equal SecurityTelemetry::AUTH_FAILURE_KINDS.sort, report[:auth_failures_by_kind].keys.sort
    assert_equal({ "missing" => 1, "unknown" => 3, "revoked" => 0, "retired" => 0, "wrong_grant" => 0, "other" => 0 },
      report[:auth_failures_by_kind_and_reason]["api_key"])
  end

  test "a reason nobody listed is counted as other, so no caller can mint a series" do
    report = with_security_telemetry do
      SecurityTelemetry.record_auth_failure(:oauth_token, "203.0.113.9")
      SecurityTelemetry.record_auth_failure(:oauth_token, nil)
    end

    reasons = report[:auth_failures_by_kind_and_reason]["oauth_token"]
    assert_equal 2, reasons["other"]
    refute reasons.key?("203.0.113.9")
  end

  test "an unknown kind is a bug at the call site and raises where tests run" do
    assert_raises(ArgumentError) { SecurityTelemetry.record_auth_failure(:password_spray, :x) }
  end

  test "responses are counted by surface, status class and 4xx code" do
    report = with_security_telemetry do
      SecurityTelemetry.record_response("/api/v1/sessions", 200)
      SecurityTelemetry.record_response("/api/v1/sessions", 401)
      SecurityTelemetry.record_response("/api/v1/nope", 404)
      SecurityTelemetry.record_response("/mcp", 401)
      SecurityTelemetry.record_response("/mcp/external_app", 418)
      SecurityTelemetry.record_response("/live/delegation_mcp", 500)
      SecurityTelemetry.record_response("/oauth/token", 400)
      SecurityTelemetry.record_response("/.well-known/oauth-authorization-server", 200)
      SecurityTelemetry.record_response("/webhooks/github", 401)
      SecurityTelemetry.record_response("/sessions/1", 302)
      SecurityTelemetry.record_response("/mcpanything", 200)
      SecurityTelemetry.record_response("/x", nil)
    end

    classes = report[:responses_by_surface_and_status_class]
    errors = report[:client_errors_by_surface_and_status]

    assert_equal({ "2xx" => 1, "3xx" => 0, "4xx" => 2, "5xx" => 0 }, classes["api"])
    assert_equal({ "2xx" => 0, "3xx" => 0, "4xx" => 2, "5xx" => 1 }, classes["mcp"])
    assert_equal({ "2xx" => 1, "3xx" => 0, "4xx" => 1, "5xx" => 0 }, classes["oauth"])
    assert_equal 1, classes["webhooks"]["4xx"]
    assert_equal({ "2xx" => 1, "3xx" => 1, "4xx" => 0, "5xx" => 0 }, classes["web"], "/mcpanything is not /mcp")
    assert_equal 1, errors["api"]["401"]
    assert_equal 1, errors["api"]["404"]
    assert_equal 1, errors["mcp"]["401"]
    assert_equal 1, errors["mcp"]["other"]
    assert_equal SecurityTelemetry::SURFACES.sort, classes.keys.sort
  end

  test "the window is the current bucket and the eleven before it" do
    store = ActiveSupport::Cache::MemoryStore.new
    Rails.stub(:cache, store) do
      SecurityTelemetry.record_auth_failure(:api_key, :unknown)
      travel 55.minutes
      SecurityTelemetry.record_auth_failure(:api_key, :unknown)
      assert_equal 2, SecurityTelemetry.report[:auth_failures_by_kind]["api_key"]

      travel 5.minutes
      assert_equal 1, SecurityTelemetry.report[:auth_failures_by_kind]["api_key"], "the first bucket has aged out"
    end
  end

  test "with no counter store, recording is a no-op and the report is all zeros" do
    SecurityTelemetry.record_auth_failure(:api_key, :unknown)
    report = SecurityTelemetry.report

    assert_equal 0, report[:auth_failures_by_kind].values.sum
  end

  test "recording never touches the store; a flush that fails drops its counts and never raises" do
    broken = Object.new
    def broken.increment(*) = raise(StandardError, "down")
    def broken.read_multi(*, **) = raise(StandardError, "down")
    Rails.stub(:cache, broken) do
      assert_nil SecurityTelemetry.record_auth_failure(:api_key, :unknown)
      assert_nil SecurityTelemetry.record_response("/api/v1/sessions", 401)
      assert_nil SecurityTelemetry.flush!
    end
  end

  test "a count stays in the process until a flush, and the flush carries its bucket" do
    store = ActiveSupport::Cache::MemoryStore.new
    Rails.stub(:cache, store) do
      SecurityTelemetry.record_auth_failure(:api_key, :unknown)
      SecurityTelemetry.record_auth_failure(:api_key, :unknown)
      key = SecurityTelemetry.key(%w[auth_failure api_key unknown], SecurityTelemetry.bucket_for(Time.current))
      assert_nil store.read(key, raw: true), "nothing reaches the store on the request path"

      travel 7.minutes
      SecurityTelemetry.flush!
      assert_equal 2, store.read(key, raw: true).to_i, "counted in the bucket it was recorded in"
      assert_equal 0, SecurityTelemetry.pending.size
    end
  end

  test "a request that raised is counted with the status Rails answers it with" do
    report = with_security_telemetry do
      ActiveSupport::Notifications.instrument("process_action.action_controller",
        path: "/api/v1/sessions/999?x=1", status: nil, exception_object: ActiveRecord::RecordNotFound.new)
      ActiveSupport::Notifications.instrument("process_action.action_controller",
        path: "/mcp", status: nil, exception_object: RuntimeError.new)
    end

    assert_equal 1, report[:client_errors_by_surface_and_status]["api"]["404"]
    assert_equal 1, report[:responses_by_surface_and_status_class]["mcp"]["5xx"]
  end

  # The kind check raises only at call sites a test reaches. This one reads them
  # all, so a typo anywhere in app/ fails here rather than logging in production.
  test "every record_auth_failure call site names a known kind" do
    calls = Dir[Rails.root.join("app/**/*.rb")].flat_map do |file|
      File.read(file).scan(/record_auth_failure\(:(\w+)/).flatten
    end

    assert_operator calls.size, :>=, 15
    assert_empty calls.uniq - SecurityTelemetry::AUTH_FAILURE_KINDS
    assert_empty SecurityTelemetry::AUTH_FAILURE_KINDS - calls.uniq, "a kind nothing records"
  end
end
