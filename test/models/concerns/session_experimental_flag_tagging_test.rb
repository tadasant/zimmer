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

  test "pausing records the end value, and a toggle between the two shows up" do
    set_tool_search(true)
    @session.start!
    set_tool_search(false)

    @session.pause!

    assert_equal true, flag.value_at_start
    assert_equal false, flag.value_at_end
    assert_equal "mixed", flag.cohort, "a setting toggled mid-session belongs to neither cohort"
  end

  test "a session that fails is still tagged at both ends" do
    set_tool_search(false)
    @session.start!

    @session.fail!

    assert_equal "off", flag.cohort
  end

  test "archiving records the end value for a session that never paused" do
    set_tool_search(true)
    @session.start!
    set_tool_search(false)

    @session.archive!

    assert_equal false, flag.value_at_end
  end

  test "a failure to tag never blocks a transition" do
    SessionExperimentalFlag.stubs(:record!).raises(StandardError, "boom")

    assert_nothing_raised { @session.start! }
    assert @session.running?
  end
end
