# frozen_string_literal: true

require "test_helper"
require "support/work_backlog_helpers"

# The one write behind every hold, and the rows it refuses to silence.
class WorkBacklog::HoldTest < ActiveSupport::TestCase
  include WorkBacklogHelpers

  setup do
    sessions(:archived).update_columns(archived_at: 2.days.ago)
  end

  test "holds a stranded row with its reason, author, session and evidence" do
    item = stranded_row(state: WorkBacklogItem::LIVENESS_PR_MERGED_ISSUE_OPEN)

    freeze_time do
      WorkBacklog::Hold.call(item: item, reason: "  pick #79/#141/#217  ", by: "fleet-maintenance",
                             session: sessions(:running))

      item.reload
      assert_equal "pick #79/#141/#217", item.hold_reason
      assert_equal "fleet-maintenance", item.held_by
      assert_equal sessions(:running), item.held_by_session
      assert_equal Time.current, item.held_at
      assert_equal Time.current + WorkBacklogItem::HOLD_DURATION, item.held_until
      assert_equal WorkBacklogItem::LIVENESS_PR_MERGED_ISSUE_OPEN, item.held_liveness_state
    end
  end

  test "refuses a blank reason" do
    item = stranded_row
    error = assert_raises(WorkBacklog::Hold::Refused) { WorkBacklog::Hold.call(item: item, reason: " ", by: "x") }
    assert_match(/reason is required/, error.message)
    assert_nil item.reload.held_at
  end

  test "refuses a row that is not stranded" do
    queued = backlog_item(key: "zimmer#9")
    running = backlog_item(key: "zimmer#8")
    running.mark_started!(session: sessions(:running), by: nil)
    resolved = stranded_row(key: "zimmer#7", state: WorkBacklogItem::LIVENESS_PR_OPEN)

    [ queued, running, resolved ].each do |item|
      error = assert_raises(WorkBacklog::Hold::Refused) { WorkBacklog::Hold.call(item: item, reason: "r", by: "x") }
      assert_match(/is not stranded/, error.message)
    end
  end

  test "refuses a row whose evidence has not been read" do
    [ nil, WorkBacklogItem::LIVENESS_UNKNOWN ].each_with_index do |state, i|
      item = stranded_row(key: "zimmer##{i + 1}", state: state)
      error = assert_raises(WorkBacklog::Hold::Refused) { WorkBacklog::Hold.call(item: item, reason: "r", by: "x") }
      assert_match(/no liveness evidence/, error.message)
    end
  end

  test "refuses to extend an active hold, or renew a lapsed one before its lapse has paged" do
    item = stranded_row
    WorkBacklog::Hold.call(item: item, reason: "first", by: "x")

    error = assert_raises(WorkBacklog::Hold::Refused) { WorkBacklog::Hold.call(item: item, reason: "again", by: "x") }
    assert_match(/already held/, error.message)

    later = item.reload.held_until + 1.minute
    error = assert_raises(WorkBacklog::Hold::Refused) do
      WorkBacklog::Hold.call(item: item, reason: "renewed quietly", by: "x", now: later)
    end
    assert_match(/has not paged on the lapse yet/, error.message)

    # What the sweep does once it has paged on the lapse.
    item.update_columns(WorkBacklogItem::CLEARED_HOLD)
    WorkBacklog::Hold.call(item: item, reason: "still owed", by: "x", now: later)
    assert_equal "still owed", item.reload.hold_reason
    assert_equal later + WorkBacklogItem::HOLD_DURATION, item.held_until
  end

  test "refuses a row a newer row has taken over" do
    item = stranded_row
    backlog_item(key: item.key)

    error = assert_raises(WorkBacklog::Hold::Refused) { WorkBacklog::Hold.call(item: item, reason: "r", by: "x") }
    assert_match(/taken over by a newer row/, error.message)
  end

  test "a row that fails validation for another reason is a refusal, not an exception" do
    item = stranded_row
    item.update_columns(estimated_cost: "enormous")

    error = assert_raises(WorkBacklog::Hold::Refused) { WorkBacklog::Hold.call(item: item, reason: "r", by: "x") }
    assert_match(/could not be saved/, error.message)
  end

  private

  def stranded_row(key: "zimmer#1", state: WorkBacklogItem::LIVENESS_NO_PR)
    item = backlog_item(key: key)
    item.mark_started!(session: sessions(:archived), by: nil)
    item.record_liveness!(state) if state
    item
  end
end
