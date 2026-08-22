# frozen_string_literal: true

require "test_helper"

class ExperimentalFlagBackfillJobTest < ActiveSupport::TestCase
  LANDED = ExperimentalSettingsRegistry.find("mcp_tool_search").landed_at

  # Frozen well after the setting landed, so "after the boundary" is also "older
  # than the live recorder's grace period" no matter when the suite runs.
  NOW = LANDED + 2.days

  setup do
    travel_to NOW
    SessionExperimentalFlag.delete_all
    SessionTokenUsage.delete_all
    Session.delete_all
  end

  def session_at(created_at)
    session = create_session(title: "s#{created_at.to_i}")
    session.update_columns(created_at: created_at, updated_at: created_at)
    session
  end

  def usage_at(session, called_at)
    SessionTokenUsage.create!(
      request_id: "req_#{SecureRandom.hex(6)}", session_id: session.id,
      model: "claude-opus-5", called_at: called_at, input_tokens: 10, output_tokens: 10
    )
  end

  def flag_for(session) = SessionExperimentalFlag.find_by(session_id: session.id, setting_key: "mcp_tool_search")

  test "history is labelled from the date the setting landed" do
    before = session_at(LANDED - 3.days)
    after = session_at(LANDED + 3.hours)

    ExperimentalFlagBackfillJob.new.perform

    assert_equal "off", flag_for(before).cohort
    assert_equal "on", flag_for(after).cohort
    assert_equal SessionExperimentalFlag::BACKFILLED, flag_for(before).source
  end

  test "a session that straddles the boundary lands in neither cohort" do
    # Created before the setting landed, still billing calls after it: this
    # session ran under both values and is evidence for neither.
    straddler = session_at(LANDED - 2.hours)
    usage_at(straddler, LANDED + 2.hours)

    ExperimentalFlagBackfillJob.new.perform

    assert_equal "mixed", flag_for(straddler).cohort
  end

  test "a session with no recorded usage is labelled from its creation alone" do
    quiet = session_at(LANDED - 5.days)

    ExperimentalFlagBackfillJob.new.perform

    assert_equal "off", flag_for(quiet).cohort
  end

  test "running it again writes nothing" do
    session_at(LANDED - 1.day)
    session_at(LANDED + 1.day)

    assert_equal 2, ExperimentalFlagBackfillJob.new.perform
    assert_equal 0, ExperimentalFlagBackfillJob.new.perform
  end

  test "an observed label is never overwritten by an inferred one" do
    # The live recorder knows what the setting actually was. A date-derived guess
    # must not clobber it.
    observed = session_at(LANDED - 1.day)
    SessionExperimentalFlag.create!(
      session: observed, setting_key: "mcp_tool_search",
      value_at_start: true, value_at_end: true, source: SessionExperimentalFlag::OBSERVED
    )

    ExperimentalFlagBackfillJob.new.perform

    assert_equal SessionExperimentalFlag::OBSERVED, flag_for(observed).source
    assert_equal "on", flag_for(observed).cohort
  end

  test "a session younger than the grace period is left to the live recorder" do
    # Without the grace period a session created seconds ago — not yet started, so
    # not yet tagged — would be labelled "backfilled", and the report would then
    # report its provenance wrongly.
    fresh = session_at(1.minute.ago)

    ExperimentalFlagBackfillJob.new.perform

    assert_nil flag_for(fresh)
  end
end
