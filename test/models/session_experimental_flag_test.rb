# frozen_string_literal: true

require "test_helper"

class SessionExperimentalFlagTest < ActiveSupport::TestCase
  setup do
    @session = create_session(title: "flagged")
    AppSetting.delete_all
  end

  def flag(key = "mcp_tool_search")
    SessionExperimentalFlag.find_by(session_id: @session.id, setting_key: key)
  end

  def set_tool_search(value)
    setting = AppSetting.editable
    setting.mcp_tool_search_enabled = value
    setting.save!
  end

  test "the first observation fixes the start value and every observation moves the end value" do
    # This is the whole mechanism: one method, called at both ends of a session's
    # life, has to behave differently the first time.
    set_tool_search(true)
    SessionExperimentalFlag.record!(@session)

    assert_equal true, flag.value_at_start
    assert_equal true, flag.value_at_end

    set_tool_search(false)
    SessionExperimentalFlag.record!(@session)

    assert_equal true, flag.value_at_start, "the start value must survive a later observation"
    assert_equal false, flag.value_at_end
  end

  test "a session whose ends disagree is in neither cohort" do
    # A setting toggled mid-session makes that session evidence for nothing.
    # Silently rounding it into one side is how a crude A/B test lies.
    set_tool_search(true)
    SessionExperimentalFlag.record!(@session)
    set_tool_search(false)
    SessionExperimentalFlag.record!(@session)

    assert_equal "mixed", flag.cohort
  end

  test "cohort names each state" do
    row = SessionExperimentalFlag.new(session: @session, setting_key: "x")

    assert_equal "unknown", row.cohort

    row.value_at_start = true
    assert_equal "on", row.cohort

    row.value_at_end = true
    assert_equal "on", row.cohort

    row.value_at_start = false
    row.value_at_end = false
    assert_equal "off", row.cohort
  end

  test "recording twice writes one row per setting" do
    set_tool_search(true)

    assert_difference -> { SessionExperimentalFlag.count }, ExperimentalSettingsRegistry.all.size do
      SessionExperimentalFlag.record!(@session)
    end
    assert_no_difference -> { SessionExperimentalFlag.count } do
      SessionExperimentalFlag.record!(@session)
    end
  end

  test "an observation never rewrites a backfilled row's provenance or start value" do
    # The backfilled start is the only record that the session began before this
    # table existed. An observation at the session's END must not claim to be one
    # at its start.
    SessionExperimentalFlag.create!(
      session: @session, setting_key: "mcp_tool_search",
      value_at_start: false, value_at_end: false,
      source: SessionExperimentalFlag::BACKFILLED
    )
    set_tool_search(true)

    SessionExperimentalFlag.record!(@session)

    assert_equal SessionExperimentalFlag::BACKFILLED, flag.source
    assert_equal false, flag.value_at_start
    assert_equal true, flag.value_at_end
    assert_equal "mixed", flag.cohort
  end

  test "tagging never raises at a session it cannot tag" do
    # This runs inside session state transitions. A bookkeeping write must never
    # be the reason a session fails to start.
    assert_nothing_raised { SessionExperimentalFlag.record!(nil) }
    assert_nothing_raised { SessionExperimentalFlag.record!(Session.new) }
  end

  test "flags are destroyed with their session" do
    set_tool_search(true)
    SessionExperimentalFlag.record!(@session)

    assert_difference -> { SessionExperimentalFlag.count }, -ExperimentalSettingsRegistry.all.size do
      @session.destroy!
    end
  end
end
