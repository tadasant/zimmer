# frozen_string_literal: true

require "test_helper"
require "support/work_backlog_helpers"

# The Issues page's "hold for a decision" form. Same write as the MCP tool and
# the REST action — WorkBacklog::Hold — so these assert the browser half only.
class WorkBacklogHoldsControllerTest < ActionDispatch::IntegrationTest
  include WorkBacklogHelpers

  setup do
    sessions(:archived).update!(archived_at: 3.days.ago)
  end

  test "holds exactly the row it names, attributed to human" do
    target = stranded_row("zimmer#79")
    other = stranded_row("zimmer#80")

    post hold_work_backlog_item_path(target), params: { reason: "pick #79/#141/#217" }

    assert_redirected_to issues_path
    assert_equal [ target.id ], WorkBacklogItem.awaiting_decision.pluck(:id)
    assert_equal "human", target.reload.held_by
    assert_equal "pick #79/#141/#217", target.hold_reason
    assert_nil other.reload.held_at
    assert_match "zimmer#79", flash[:notice]
  end

  test "a refusal comes back as an alert and writes nothing" do
    queued = backlog_item(key: "zimmer#81")

    post hold_work_backlog_item_path(queued), params: { reason: "r" }

    assert_redirected_to issues_path
    assert_match(/is not stranded/, flash[:alert])
    assert_nil queued.reload.held_at
  end

  private

  def stranded_row(key)
    item = backlog_item(key: key)
    item.mark_started!(session: sessions(:archived), by: nil, now: 4.days.ago)
    item.record_liveness!(WorkBacklogItem::LIVENESS_NO_PR)
    item
  end
end
