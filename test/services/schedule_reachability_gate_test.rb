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
    @start = Time.zone.parse("2026-10-31T10:00:00Z")
  end

  # -- probe --

  test "a server listing real tools is reachable" do
    McpApps::Client.any_instance.stubs(:tools_list).returns([ { "name" => "zimmer__get_session" } ])

    assert ScheduleReachabilityGate.probe("zimmer")["reachable"]
  end

  test "strad's troubleshoot_host placeholder alone means the host is offline" do
    McpApps::Client.any_instance.stubs(:tools_list).returns([ { "name" => "zimmer__troubleshoot_host" } ])

    probe = ScheduleReachabilityGate.probe("zimmer")
    assert_not probe["reachable"]
    assert_equal "exclude rule failed: lists zimmer__troubleshoot_host", probe["reason"]
  end

  test "one tools/list per server serves conditions with different rules" do
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
    McpApps::Client.any_instance.expects(:tools_list).once.returns([ { "name" => "zimmer__get_session" } ])

    assert ScheduleReachabilityGate.probe("zimmer")["reachable"]
    picky = ScheduleReachabilityToolRule.new(include: %w[send_message])
    assert_equal "include rule failed: lists none of send_message", ScheduleReachabilityGate.probe("zimmer", picky)["reason"]
  end

  # -- observe! with the tool rule --

  test "a condition saved with only require_reachable still treats the placeholder as offline" do
    assert_equal({ "require_reachable" => [ "zimmer" ] }, @condition.configuration.slice(*%w[require_reachable] + TriggerCondition::SCHEDULE_TOOL_RULE_KEYS))
    McpApps::Client.any_instance.stubs(:tools_list).returns([ { "name" => "zimmer__troubleshoot_host" } ])

    ScheduleReachabilityGate.observe!(@condition, now: @start)

    assert_equal "zimmer: exclude rule failed: lists zimmer__troubleshoot_host", @condition.reload.schedule_reachability_state["last_error"]
  end

  test "last_error names the include rule that failed" do
    @condition.update!(configuration: @condition.configuration.merge("reachable_tools_include" => [ "send_message" ]))
    McpApps::Client.any_instance.stubs(:tools_list).returns([ { "name" => "zimmer__get_session" } ])

    ScheduleReachabilityGate.observe!(@condition, now: @start)

    state = @condition.reload.schedule_reachability_state
    assert_nil state["reachable_since"]
    assert_equal "zimmer: include rule failed: lists none of send_message", state["last_error"]
  end

  test "a condition that excludes nothing counts the placeholder as reachable" do
    @condition.update!(configuration: @condition.configuration.merge("reachable_tools_exclude" => []))
    McpApps::Client.any_instance.stubs(:tools_list).returns([ { "name" => "zimmer__troubleshoot_host" } ])

    ScheduleReachabilityGate.observe!(@condition, now: @start)

    assert_equal @start.iso8601, @condition.reload.schedule_reachability_state["reachable_since"]
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

  # -- observe! --

  test "an unreachable observation is recorded on the condition" do
    stub_reachable(false)

    ScheduleReachabilityGate.observe!(@condition, now: @start)

    state = @condition.reload.schedule_reachability_state
    assert_nil state["reachable_since"]
    assert_equal @start.iso8601, state["unreachable_since"]
    assert_match(/offline/, state["last_error"])
  end

  test "recording writes only the gate's key, so an edit made during a probe survives" do
    stub_reachable(true)
    stale_copy = TriggerCondition.find(@condition.id)
    @condition.update!(configuration: @condition.configuration.merge("time" => "15:30"))

    ScheduleReachabilityGate.observe!(stale_copy, now: @start)

    @condition.reload
    assert_equal "15:30", @condition.schedule_time
    assert_equal @start.iso8601, @condition.schedule_reachability_state["reachable_since"]
  end

  test "reachable_since carries across observations a minute apart" do
    stub_reachable(true)

    (0..10).each { |minute| ScheduleReachabilityGate.observe!(@condition.reload, now: @start + minute.minutes) }

    assert_equal @start.iso8601, @condition.reload.schedule_reachability_state["reachable_since"]
  end

  test "an unreachable observation resets the dwell" do
    stub_reachable(true)
    ScheduleReachabilityGate.observe!(@condition, now: @start)
    stub_reachable(false)
    ScheduleReachabilityGate.observe!(@condition.reload, now: @start + 1.minute)
    stub_reachable(true)
    ScheduleReachabilityGate.observe!(@condition.reload, now: @start + 2.minutes)

    assert_equal (@start + 2.minutes).iso8601, @condition.reload.schedule_reachability_state["reachable_since"]
  end

  test "a record older than STALE_AFTER does not carry its dwell over" do
    stub_reachable(true)
    ScheduleReachabilityGate.observe!(@condition, now: @start)

    ScheduleReachabilityGate.observe!(@condition.reload, now: @start + 1.hour)

    assert_equal (@start + 1.hour).iso8601, @condition.reload.schedule_reachability_state["reachable_since"]
  end

  # -- check --

  test "an ungated condition is always open" do
    @condition.update!(configuration: @condition.configuration.except("require_reachable"))

    assert ScheduleReachabilityGate.check(@condition).open
  end

  test "check never probes" do
    McpApps::Client.any_instance.expects(:tools_list).never

    ScheduleReachabilityGate.check(@condition)
  end

  test "closed before the first observation" do
    result = ScheduleReachabilityGate.check(@condition, now: @start)

    assert_not result.open
    assert_match(/not probed yet/, result.reason)
  end

  test "closed while unreachable" do
    stub_reachable(false)
    ScheduleReachabilityGate.observe!(@condition, now: @start)

    assert_not ScheduleReachabilityGate.check(@condition.reload, now: @start).open
  end

  test "opens only once the server has been reachable for the dwell" do
    stub_reachable(true)
    (0..9).each do |minute|
      ScheduleReachabilityGate.observe!(@condition.reload, now: @start + minute.minutes)
      assert_not ScheduleReachabilityGate.check(@condition, now: @start + minute.minutes).open
    end

    ScheduleReachabilityGate.observe!(@condition.reload, now: @start + 10.minutes)
    assert ScheduleReachabilityGate.check(@condition, now: @start + 10.minutes).open
  end

  test "closed on a stale record, even one that said reachable" do
    stub_reachable(true)
    ScheduleReachabilityGate.observe!(@condition, now: @start - 1.hour)

    result = ScheduleReachabilityGate.check(@condition.reload, now: @start)
    assert_not result.open
    assert_match(/stale/, result.reason)
  end

  test "a zero dwell opens on the first reachable observation" do
    stub_reachable(true)
    @condition.update!(configuration: @condition.configuration.merge("reachable_dwell_minutes" => 0))
    ScheduleReachabilityGate.observe!(@condition, now: @start)

    assert ScheduleReachabilityGate.check(@condition.reload, now: @start).open
  end

  private

  def stub_reachable(reachable)
    ScheduleReachabilityGate.stubs(:probe).returns({ "reachable" => reachable, "reason" => reachable ? nil : "offline" })
  end
end
