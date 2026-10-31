# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class ScheduleReachabilityGateTest < ActiveSupport::TestCase
  setup do
    @condition = trigger_conditions(:enabled_schedule_condition)
    # `zimmer` is a streamable-http server in the test catalog.
    @condition.update!(configuration: @condition.configuration.merge("require_reachable" => [ "zimmer" ]))
    McpServerEndpoint.any_instance.stubs(:url).returns("https://strad.example/mcp?servers=zimmer")
    McpServerEndpoint.any_instance.stubs(:headers).returns({})
  end

  test "an ungated condition is always open and probes nothing" do
    @condition.update!(configuration: @condition.configuration.except("require_reachable"))
    McpApps::Client.any_instance.expects(:tools_list).never

    assert ScheduleReachabilityGate.check(@condition).open
  end

  test "a server listing real tools is reachable" do
    McpApps::Client.any_instance.stubs(:tools_list).returns([ { "name" => "zimmer__get_session" } ])

    assert ScheduleReachabilityGate.probe("zimmer")["reachable"]
  end

  test "strad's troubleshoot_host placeholder alone means the host is offline" do
    McpApps::Client.any_instance.stubs(:tools_list).returns([ { "name" => "zimmer__troubleshoot_host" } ])

    probe = ScheduleReachabilityGate.probe("zimmer")
    assert_not probe["reachable"]
    assert_match(/troubleshoot_host/, probe["reason"])
  end

  test "a transport error is unreachable, not a raise" do
    McpApps::Client.any_instance.stubs(:tools_list).raises(McpApps::Client::Error, "MCP server returned HTTP 530")

    probe = ScheduleReachabilityGate.probe("zimmer")
    assert_not probe["reachable"]
    assert_match(/530/, probe["reason"])
  end

  test "a server the catalog does not carry is unreachable" do
    assert_not ScheduleReachabilityGate.probe("no-such-server")["reachable"]
  end

  test "closed while unreachable, and the observation is recorded on the condition" do
    McpApps::Client.any_instance.stubs(:tools_list).raises(McpApps::Client::Error, "could not reach MCP server: Errno::ECONNREFUSED")
    now = Time.zone.parse("2026-10-31T10:00:00Z")

    result = ScheduleReachabilityGate.check(@condition, now: now)

    assert_not result.open
    state = @condition.reload.schedule_reachability_state
    assert_nil state["reachable_since"]
    assert_equal now.iso8601, state["unreachable_since"]
    assert_match(/ECONNREFUSED/, state["last_error"])
  end

  test "opens only once the server has been reachable for the dwell" do
    McpApps::Client.any_instance.stubs(:tools_list).returns([ { "name" => "zimmer__get_session" } ])
    start = Time.zone.parse("2026-10-31T10:00:00Z")

    # Each tick re-checks well inside STALE_AFTER, so the dwell carries across them.
    (0..9).each do |minute|
      assert_not ScheduleReachabilityGate.check(@condition.reload, now: start + minute.minutes).open
    end

    assert ScheduleReachabilityGate.check(@condition.reload, now: start + 10.minutes).open
    assert_equal start.iso8601, @condition.reload.schedule_reachability_state["reachable_since"]
  end

  test "a dwell recorded during an earlier due period does not carry over" do
    McpApps::Client.any_instance.stubs(:tools_list).returns([ { "name" => "zimmer__get_session" } ])
    yesterday = Time.zone.parse("2026-10-30T10:00:00Z")
    @condition.update_column(:configuration, @condition.configuration.merge(
      "reachability" => { "reachable_since" => (yesterday - 1.hour).iso8601, "last_checked_at" => yesterday.iso8601 }
    ))
    now = yesterday + 1.day

    assert_not ScheduleReachabilityGate.check(@condition, now: now).open
    assert_equal now.iso8601, @condition.reload.schedule_reachability_state["reachable_since"]
  end

  test "an unreachable tick resets the dwell" do
    start = Time.zone.parse("2026-10-31T10:00:00Z")
    McpApps::Client.any_instance.stubs(:tools_list).returns([ { "name" => "zimmer__get_session" } ])
    ScheduleReachabilityGate.check(@condition, now: start)

    McpApps::Client.any_instance.stubs(:tools_list).returns([ { "name" => "zimmer__troubleshoot_host" } ])
    ScheduleReachabilityGate.check(@condition.reload, now: start + 1.minute)

    McpApps::Client.any_instance.stubs(:tools_list).returns([ { "name" => "zimmer__get_session" } ])
    result = ScheduleReachabilityGate.check(@condition.reload, now: start + 11.minutes)

    assert_not result.open
    assert_equal (start + 11.minutes).iso8601, @condition.reload.schedule_reachability_state["reachable_since"]
  end

  test "a zero dwell opens on the first reachable tick" do
    McpApps::Client.any_instance.stubs(:tools_list).returns([ { "name" => "zimmer__get_session" } ])
    @condition.update!(configuration: @condition.configuration.merge("reachable_dwell_minutes" => 0))

    assert ScheduleReachabilityGate.check(@condition).open
  end
end
