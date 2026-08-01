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
    AlertService.expects(:raise_alert).never

    ElicitationEndpointHealthCheckJob.new.perform

    assert_not ElicitationEndpoint.unreachable?
  end

  test "alerts on the transition into unreachable" do
    ElicitationEndpoint.stubs(:probe).returns(probe_result(reachable: false, detail: "SocketError: no such host"))

    AlertService.expects(:raise_alert).with do |title, opts|
      title == "MCP approval gate unreachable" &&
        opts[:dedup_key] == ElicitationEndpointHealthCheckJob::ALERT_DEDUP_KEY &&
        # The probe's raw failure is carried as the log snippet, not as prose.
        opts[:error].include?("SocketError: no such host")
    end

    ElicitationEndpointHealthCheckJob.new.perform

    assert ElicitationEndpoint.unreachable?
  end

  test "does not re-alert while it stays unreachable" do
    ElicitationEndpoint.stubs(:probe).returns(probe_result(reachable: false))

    AlertService.expects(:raise_alert).once
    ElicitationEndpointHealthCheckJob.new.perform
    ElicitationEndpointHealthCheckJob.new.perform
  end

  test "clears the unreachable status on recovery" do
    ElicitationEndpoint.record(probe_result(reachable: false))
    assert ElicitationEndpoint.unreachable?

    ElicitationEndpoint.stubs(:probe).returns(probe_result(reachable: true, detail: "HTTP 404"))
    AlertService.stubs(:raise_alert)

    ElicitationEndpointHealthCheckJob.new.perform

    assert_not ElicitationEndpoint.unreachable?
  end
end
