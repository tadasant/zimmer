# frozen_string_literal: true

require "test_helper"
require "support/work_backlog_helpers"

# The browser boundary for hand-placing a queued item.
#
# Everything here is about one property: a click on the Issues page pins or
# unpins EXACTLY the item it names, at exactly the precedence it was given, and
# does nothing at all when the item cannot take a pin. The boundary is
# browser-vs-API-key, not human-vs-agent — see the controller.
class WorkBacklogPinsControllerTest < ActionDispatch::IntegrationTest
  include WorkBacklogHelpers

  test "pins exactly the item it names, at the precedence given" do
    item = backlog_item(key: "zimmer#498", precedence: 6000)
    other = backlog_item(key: "zimmer#499", precedence: 5990)

    post pin_work_backlog_item_path(item), params: { precedence: 6500 }

    assert_redirected_to issues_path
    item.reload
    assert item.pinned?
    assert_equal 6500, item.precedence
    assert_match "zimmer#498", flash[:notice]
    assert_match "6500", flash[:notice]

    other.reload
    assert_not other.pinned?, "only the item that was clicked is pinned"
    assert_equal 5990, other.precedence, "an unpinned peer already inside its band is not moved"
  end

  test "a pin outside the item's cost band survives the re-rank every writer runs" do
    # The whole point of a pin: WorkBacklog::Ranking never re-bands a pinned item,
    # so a `small` item hand-placed down in the `large` band stays there.
    item = backlog_item(key: "zimmer#498", cost: "small", precedence: 6000)

    post pin_work_backlog_item_path(item), params: { precedence: 900 }

    item.reload
    assert item.pinned?
    assert_equal 900, item.precedence
    assert_not item.in_band?
  end

  test "unpin releases the pin and re-ranks the item back into its cost band" do
    pinned = backlog_item(key: "zimmer#498", cost: "small", precedence: 900, pinned: true)
    other = backlog_item(key: "zimmer#499", cost: "small", precedence: 6000)

    delete unpin_work_backlog_item_path(pinned)

    assert_redirected_to issues_path
    pinned.reload
    assert_not pinned.pinned?
    assert pinned.in_band?, "the re-rank puts an unpinned item back inside its band"
    assert_equal WorkBacklog::Ranking::GAP, other.reload.precedence - pinned.precedence
    assert_match "zimmer#498", flash[:notice]
  end

  test "a pin with no precedence changes nothing and says so" do
    item = backlog_item(key: "zimmer#498", precedence: 6000)

    post pin_work_backlog_item_path(item), params: { precedence: "" }

    item.reload
    assert_not item.pinned?
    assert_equal 6000, item.precedence
    assert_match(/needs a precedence/, flash[:alert])
  end

  test "a precedence that is not a whole number is a message, not a 500" do
    item = backlog_item(key: "zimmer#498", precedence: 6000)

    post pin_work_backlog_item_path(item), params: { precedence: "top" }

    item.reload
    assert_not item.pinned?
    assert_equal 6000, item.precedence
    assert_match(/not a whole number/, flash[:alert])
  end

  test "a precedence past what the column holds is a message, not a 500" do
    item = backlog_item(key: "zimmer#498", precedence: 6000)

    post pin_work_backlog_item_path(item), params: { precedence: WorkBacklogItem::PRECEDENCE_RANGE.last + 1 }

    item.reload
    assert_not item.pinned?
    assert_equal 6000, item.precedence
    assert_match(/Could not pin/, flash[:alert])
  end

  test "an item that is no longer queued cannot be pinned or unpinned" do
    started = backlog_item(key: "zimmer#498")
    started.mark_started!(session: sessions(:running), by: nil)
    removed = backlog_item(key: "zimmer#499", pinned: true)
    removed.remove!(reason: "not worth doing", by: "human")

    post pin_work_backlog_item_path(started), params: { precedence: 6500 }
    assert_match(/is started, so it cannot be pinned/, flash[:alert])
    assert_not started.reload.pinned?

    delete unpin_work_backlog_item_path(removed)
    assert_match(/is removed, so it cannot be unpinned/, flash[:alert])
    assert removed.reload.pinned?, "a removed item's history is left exactly as it was"
  end

  test "an item that no longer exists is a message, not a 500" do
    post pin_work_backlog_item_path(id: 999_999), params: { precedence: 6500 }
    assert_redirected_to issues_path
    assert_match(/no longer exists/, flash[:alert])

    delete unpin_work_backlog_item_path(id: 999_999)
    assert_redirected_to issues_path
    assert_match(/no longer exists/, flash[:alert])
  end

  test "the redirect rebuilds the page the control was on from the query the form carried" do
    item = backlog_item(key: "zimmer#498")
    view = { repo: "tadasant/zimmer", window: 90, segment: "repo", gh_page: 2 }

    post pin_work_backlog_item_path(item, **view), params: { precedence: 6500 }
    assert_redirected_to issues_path(**view)

    delete unpin_work_backlog_item_path(item, **view)
    assert_redirected_to issues_path(**view)
  end

  test "the redirect does not depend on a Referer header" do
    item = backlog_item(key: "zimmer#498")

    post pin_work_backlog_item_path(item), params: { precedence: 6500 },
         headers: { "HTTP_REFERER" => "https://evil.example.com/" }

    assert_redirected_to issues_path
  end

  test "the browser route carries no API key of its own" do
    # The guardrail this controller exists for: it is an ApplicationController
    # descendant, so it neither reads nor requires the key the whole fleet holds.
    assert_operator WorkBacklogPinsController, :<, ApplicationController
    assert_not WorkBacklogPinsController <= Api::BaseController
  end
end
