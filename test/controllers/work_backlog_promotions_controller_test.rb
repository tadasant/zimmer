# frozen_string_literal: true

require "test_helper"
require "support/work_backlog_helpers"

# The browser boundary for the queue's one human lever.
#
# Everything here is about one property: a click on the Issues page starts
# EXACTLY ONE priority session for the item it names, marks that item started,
# and does nothing at all when the item is not startable. The boundary is
# browser-vs-API-key, not human-vs-agent — see the controller.
class WorkBacklogPromotionsControllerTest < ActionDispatch::IntegrationTest
  include WorkBacklogHelpers

  test "promotes a queued item to exactly one priority session and marks it started" do
    item = backlog_item(key: "zimmer#498", precedence: 6000)
    other = backlog_item(key: "zimmer#499", precedence: 5990)

    assert_difference("Session.count", 1) do
      post promote_work_backlog_item_path(item)
    end

    session = Session.order(:id).last
    assert_redirected_to issues_path(promoted_session_id: session.id)
    assert_equal SessionGenesis::PRIORITY, session.scheduling_class
    assert_equal SessionGenesis::WEB_UI, session.genesis
    assert_equal WorkBacklog::Start.agent_root, session.metadata["agent_root_key"]
    assert_equal WorkBacklog::Start::GOAL, session.goal
    assert_equal WorkBacklog::Start::SPAWNED_BY, session.custom_metadata["spawned_by"]
    assert_equal item.id, session.custom_metadata["work_backlog_item_id"]
    assert_equal "https://github.com/tadasant/zimmer/issues/498\n\nPlease implement this.", session.prompt
    assert_nil session.parent_session_id, "a promote comes from a browser, not from a groomer"

    item.reload
    assert item.started?
    assert_equal session.id, item.started_session_id
    assert_nil item.started_by_session_id
    assert item.started_at.present?

    assert other.reload.queued?, "only the item that was clicked is started"
    assert_match "zimmer#498", flash[:notice]
    assert_nil flash[:promoted_session_id],
               "the session id travels in the URL, not as a flash key the layout would render as its own toast"
  end

  test "a second click on an already-started item starts nothing and says so" do
    item = backlog_item(key: "zimmer#498")
    item.mark_started!(session: sessions(:running), by: nil)

    assert_no_difference("Session.count") { post promote_work_backlog_item_path(item) }

    assert_redirected_to issues_path
    assert_match(/Nothing was started/, flash[:alert])
    assert_equal sessions(:running).id, item.reload.started_session_id
  end

  test "a removed item cannot be promoted" do
    item = backlog_item(key: "zimmer#498")
    item.remove!(reason: "not worth doing", by: "human")

    assert_no_difference("Session.count") { post promote_work_backlog_item_path(item) }

    assert_match(/Nothing was started/, flash[:alert])
    assert item.reload.removed?
  end

  test "an item that no longer exists is a message, not a 500" do
    assert_no_difference("Session.count") { post promote_work_backlog_item_path(id: 999_999) }

    assert_redirected_to issues_path
    assert_match(/no longer exists/, flash[:alert])
  end

  test "the redirect rebuilds the page the button was on from the query the form carried" do
    item = backlog_item(key: "zimmer#498")

    post promote_work_backlog_item_path(item, repo: "tadasant/zimmer", window: 90, segment: "repo", gh_page: 2)

    session = Session.order(:id).last
    assert_redirected_to issues_path(repo: "tadasant/zimmer", window: 90, segment: "repo", gh_page: 2,
                                     promoted_session_id: session.id)
  end

  test "the redirect does not depend on a Referer header" do
    item = backlog_item(key: "zimmer#498")

    post promote_work_backlog_item_path(item), headers: { "HTTP_REFERER" => "https://evil.example.com/" }

    assert_redirected_to issues_path(promoted_session_id: Session.order(:id).last.id)
  end

  test "a session the spawn itself refuses is reported rather than 500ing the button" do
    item = backlog_item(key: "zimmer#498")

    Session.stub(:create_from_agent_root!, ->(**) { raise ActiveRecord::RecordInvalid, Session.new }) do
      assert_no_difference("Session.count") { post promote_work_backlog_item_path(item) }
    end

    assert_redirected_to issues_path
    assert_match(/Could not start a session/, flash[:alert])
    assert item.reload.queued?, "a refused spawn leaves the item on the queue"
  end

  test "an agent root that is not in the catalog is reported rather than raised" do
    item = backlog_item(key: "zimmer#498")

    AgentRootsConfig.stub(:find!, ->(*) { raise AgentRootsConfig::AgentRootNotFoundError, "no such root" }) do
      assert_no_difference("Session.count") { post promote_work_backlog_item_path(item) }
    end

    assert_match(/Cannot spawn a session/, flash[:alert])
    assert item.reload.queued?
  end
end
