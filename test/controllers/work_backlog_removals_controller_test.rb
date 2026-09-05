# frozen_string_literal: true

require "test_helper"
require "support/work_backlog_helpers"

# The browser boundary for taking a queued item off the queue by judgement.
#
# THE PROPERTY THAT MATTERS MOST HERE IS WHICH ROW. A remove silently drops
# queued work and there is no new session to notice it, so the first test asserts
# the acted-on row id — a form wired to the wrong row is caught by the suite
# rather than in production. The boundary is browser-vs-API-key, not
# human-vs-agent; see the controller.
class WorkBacklogRemovalsControllerTest < ActionDispatch::IntegrationTest
  include WorkBacklogHelpers

  test "removes exactly the row it names and leaves every other row queued" do
    first = backlog_item(key: "zimmer#497", precedence: 6010)
    target = backlog_item(key: "zimmer#498", precedence: 6000)
    last = backlog_item(key: "zimmer#499", precedence: 5990)

    assert_no_difference("WorkBacklogItem.count") do
      post remove_work_backlog_item_path(target), params: { reason: "superseded by #500" }
    end

    assert_redirected_to issues_path

    # The acted-on row, by id: the id in the URL is the only thing that decides
    # which item is removed, and this is the assertion that catches a form
    # rendering one row's controls with another row's id.
    removed = WorkBacklogItem.removed
    assert_equal [ target.id ], removed.pluck(:id)
    assert_equal "superseded by #500", target.reload.removal_reason
    assert_equal WorkBacklogRemovalsController::REMOVED_BY, target.removed_by
    assert target.removed_at.present?

    assert first.reload.queued?
    assert last.reload.queued?
    assert_equal %w[zimmer#497 zimmer#499], queued_keys
    assert_match "zimmer#498", flash[:notice]
  end

  test "a removal with no reason changes nothing and says so" do
    item = backlog_item(key: "zimmer#498")

    post remove_work_backlog_item_path(item), params: { reason: "  " }

    assert item.reload.queued?
    assert_nil item.removal_reason
    assert_match(/needs a reason/, flash[:alert])
  end

  test "an item that is not queued cannot be removed again" do
    started = backlog_item(key: "zimmer#498")
    started.mark_started!(session: sessions(:running), by: nil)
    already = backlog_item(key: "zimmer#499")
    already.remove!(reason: "issue_closed", by: "api")

    post remove_work_backlog_item_path(started), params: { reason: "changed my mind" }
    assert_match(/is started, so it cannot be removed/, flash[:alert])
    assert started.reload.started?

    post remove_work_backlog_item_path(already), params: { reason: "changed my mind" }
    assert_match(/is removed, so it cannot be removed/, flash[:alert])
    assert_equal "issue_closed", already.reload.removal_reason, "the first removal's reason is not overwritten"
  end

  test "an item that no longer exists is a message, not a 500" do
    post remove_work_backlog_item_path(id: 999_999), params: { reason: "gone" }

    assert_redirected_to issues_path
    assert_match(/no longer exists/, flash[:alert])
  end

  test "the queue is re-ranked after a removal, through the same lock every writer takes" do
    backlog_item(key: "zimmer#497", cost: "small", precedence: 6000)
    drifted = backlog_item(key: "zimmer#498", cost: "small", precedence: 100)
    doomed = backlog_item(key: "zimmer#499", cost: "small", precedence: 5990)

    post remove_work_backlog_item_path(doomed), params: { reason: "not worth doing" }

    assert drifted.reload.in_band?, "a removal re-ranks, so a drifted peer lands back inside its band"
  end

  test "the redirect rebuilds the page the control was on from the query the form carried" do
    item = backlog_item(key: "zimmer#498")

    post remove_work_backlog_item_path(item, repo: "tadasant/zimmer", window: 90, segment: "repo", gh_page: 2),
         params: { reason: "issue_closed" }

    assert_redirected_to issues_path(repo: "tadasant/zimmer", window: 90, segment: "repo", gh_page: 2)
  end

  test "the redirect does not depend on a Referer header" do
    item = backlog_item(key: "zimmer#498")

    post remove_work_backlog_item_path(item), params: { reason: "issue_closed" },
         headers: { "HTTP_REFERER" => "https://evil.example.com/" }

    assert_redirected_to issues_path
  end

  test "the browser route carries no API key of its own" do
    assert_operator WorkBacklogRemovalsController, :<, ApplicationController
    assert_not WorkBacklogRemovalsController <= Api::BaseController
  end
end
