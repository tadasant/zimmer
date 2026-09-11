# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class ElicitationEndpointHealthCheckJobTest < ActiveSupport::TestCase
  # The test env's cache is :null_store, which would make every write a no-op and
  # every status read nil. Swap in a real store so these tests drive the actual
  # record/read path rather than a store that agrees with everything.
  setup do
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    Rails.cache.delete(ElicitationEndpoint::CACHE_KEY)
  end

  teardown do
    Rails.cache = @original_cache
  end

  def probe_result(reachable:, detail: "detail")
    ElicitationEndpoint::Result.new(reachable: reachable, detail: detail, url: "https://zimmer.example.com/api/v1/elicitations")
  end

  test "records a healthy probe and raises no alert" do
    ElicitationEndpoint.stubs(:probe).returns(probe_result(reachable: true, detail: "HTTP 404"))
    ErrorReporter.expects(:report_message).never

    ElicitationEndpointHealthCheckJob.new.perform

    assert_not ElicitationEndpoint.unreachable?
  end

  test "alerts on the transition into unreachable" do
    ElicitationEndpoint.stubs(:probe).returns(probe_result(reachable: false, detail: "SocketError: no such host"))

    ErrorReporter.expects(:report_message).with do |message, opts|
      message == "MCP approval gate unreachable" &&
        opts[:level] == :error &&
        opts[:context][:source] == "ElicitationEndpointHealthCheckJob" &&
        # The probe's raw failure rides as a redacted snippet, not as prose.
        opts[:context][:probe_detail].include?("SocketError: no such host")
    end

    entries = capture_log_entries { ElicitationEndpointHealthCheckJob.new.perform }

    assert ElicitationEndpoint.unreachable?
    errors = entries.select { |severity, _message| severity == "ERROR" }
    assert_equal 1, errors.size, "the transition emits the ERROR record that pages"
    assert_match(/MCP approval gate unreachable/, errors.first.last)
  end

  test "does not re-alert while it stays unreachable" do
    ElicitationEndpoint.stubs(:probe).returns(probe_result(reachable: false))

    ErrorReporter.expects(:report_message).once
    ElicitationEndpointHealthCheckJob.new.perform
    ElicitationEndpointHealthCheckJob.new.perform
  end

  test "clears the unreachable status on recovery" do
    ElicitationEndpoint.record(probe_result(reachable: false))
    assert ElicitationEndpoint.unreachable?

    ElicitationEndpoint.stubs(:probe).returns(probe_result(reachable: true, detail: "HTTP 404"))
    ErrorReporter.stubs(:report_message)

    ElicitationEndpointHealthCheckJob.new.perform

    assert_not ElicitationEndpoint.unreachable?
  end
end
