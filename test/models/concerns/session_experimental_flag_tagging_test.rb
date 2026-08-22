# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# The tagging seam, exercised through the state machine rather than by calling the
# recorder directly — the point is that a session picks up its cohort label by
# living its normal life, with nothing at the call site to remember.
class SessionExperimentalFlagTaggingTest < ActiveSupport::TestCase
  setup do
    AppSetting.delete_all
    @session = create_session(title: "tagged")
  end

  def flag = SessionExperimentalFlag.find_by(session_id: @session.id, setting_key: "mcp_tool_search")

  def set_tool_search(value)
    setting = AppSetting.editable
    setting.mcp_tool_search_enabled = value
    setting.save!
  end

  test "starting a session records what every experimental setting was" do
    set_tool_search(true)

    @session.start!

    assert_equal true, flag.value_at_start
    assert_equal SessionExperimentalFlag::OBSERVED, flag.source
  end

  test "resuming after a toggle moves the end value, and the session leaves both cohorts" do
    # The setting takes effect in the spawn environment, so a resume is the moment
    # the session starts running under a different value. That is what makes the
    # two ends disagree, and a session that ran under both is evidence for neither.
    set_tool_search(true)
    @session.start!
    @session.pause!
    set_tool_search(false)

    @session.resume!

    assert_equal true, flag.value_at_start
    assert_equal false, flag.value_at_end
    assert_equal "mixed", flag.cohort
  end

  test "a terminal transition long after the session ran does not restamp its end value" do
    # HealthMonitorService#archive_old_sessions archives everything untouched for
    # seven days in a loop. Recording there would re-stamp every old session's end
    # value with today's setting, flip it to `mixed`, and drain the control cohort
    # of the comparison this data exists to support.
    set_tool_search(false)
    @session.start!
    @session.pause!
    set_tool_search(true)

    @session.archive!

    assert_equal false, flag.value_at_end
    assert_equal "off", flag.cohort
  end

  test "failing after a toggle does not restamp the end value either" do
    set_tool_search(false)
    @session.start!
    set_tool_search(true)

    @session.fail!

    assert_equal "off", flag.cohort
  end

  test "a session that only ever started carries the same value at both ends" do
    # It ran under exactly one spawn, so it ran under exactly one value.
    set_tool_search(true)
    @session.start!

    assert_equal true, flag.value_at_start
    assert_equal true, flag.value_at_end
    assert_equal "on", flag.cohort
  end

  test "a failure to tag never blocks a transition" do
    SessionExperimentalFlag.stubs(:record!).raises(StandardError, "boom")

    assert_nothing_raised { @session.start! }
    assert @session.running?
  end
end
