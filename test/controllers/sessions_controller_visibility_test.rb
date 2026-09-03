require "test_helper"
require "mocha/minitest"

# The dashboard half of board visibility: the PATCH endpoint the card menu drives,
# and the Filters section's reveal control.
#
# The property these tests exist to hold is that visibility narrows what is DRAWN
# and nothing else — a snoozed session keeps its status, its class and its rank,
# and is one radio button away from being on screen again.
class SessionsControllerVisibilityTest < ActionDispatch::IntegrationTest
  def setup
    Session.any_instance.stubs(:broadcast_status_change)
    Session.any_instance.stubs(:broadcast_update_to_sessions_index)
    Session.any_instance.stubs(:broadcast_create_to_sessions_index)
    Session.any_instance.stubs(:broadcast_remove_from_sessions_index)

    McpOauthPendingFlow.delete_all
    Notification.delete_all
    Log.delete_all
    Session.delete_all
    Category.delete_all
    AppSetting.delete_all
  end

  def make_session(title: "A session", **attrs)
    Session.create!({
      agent_runtime: "claude_code",
      status: :needs_input,
      prompt: "p",
      title: title,
      mcp_servers: [],
      config: {},
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem"
    }.merge(attrs))
  end

  # ---- The endpoint ----------------------------------------------------------

  test "hides a session and answers with the board state" do
    session = make_session

    patch update_visibility_session_path(session),
      params: { visibility: "hidden" }.to_json,
      headers: { "Content-Type" => "application/json", "Accept" => "application/json" }

    assert_response :success
    body = JSON.parse(response.body)
    assert body["success"]
    assert_equal "hidden", body["visibility"]
    assert_equal false, body["board_visible"]
    assert_equal SessionVisibility::HIDDEN, session.reload.visibility
  end

  test "snoozes to a wall-clock time in the browser's zone" do
    session = make_session
    at = Time.use_zone("America/Los_Angeles") { 2.days.from_now.change(hour: 9, min: 0) }

    patch update_visibility_session_path(session),
      params: {
        visibility: "snoozed",
        snoozed_until: at.strftime("%Y-%m-%dT%H:%M:%S"),
        timezone: "America/Los_Angeles"
      }.to_json,
      headers: { "Content-Type" => "application/json", "Accept" => "application/json" }

    assert_response :success
    session.reload
    assert_equal SessionVisibility::SNOOZED, session.visibility
    assert_equal 9, session.snoozed_until.in_time_zone("America/Los_Angeles").hour
  end

  test "refuses a snooze in the past and changes nothing" do
    session = make_session

    patch update_visibility_session_path(session),
      params: { visibility: "snoozed", snoozed_until: "2020-01-01T09:00:00", timezone: "UTC" }.to_json,
      headers: { "Content-Type" => "application/json", "Accept" => "application/json" }

    assert_response :unprocessable_entity
    assert_equal SessionVisibility::VISIBLE, session.reload.visibility
  end

  # The whole point of the feature, stated as a test: no lifecycle machinery runs.
  test "hiding a session neither changes its status nor arms a trigger" do
    session = make_session(status: :waiting, scheduling_class: "spot", precedence: 777)

    assert_no_difference -> { Trigger.count } do
      patch update_visibility_session_path(session),
        params: { visibility: "hidden" }.to_json,
        headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
    end

    session.reload
    assert_equal "waiting", session.status
    assert_equal "spot", session.scheduling_class
    assert_equal 777, session.precedence
  end

  # ---- The board -------------------------------------------------------------

  test "the default board leaves hidden and snoozed sessions out" do
    on_board = make_session(title: "On the board")
    hidden = make_session(title: "Tidied away", visibility: SessionVisibility::HIDDEN)
    snoozed = make_session(title: "Back on Friday", visibility: SessionVisibility::SNOOZED, snoozed_until: 3.days.from_now)

    get root_path

    assert_response :success
    assert_select "##{ActionView::RecordIdentifier.dom_id(on_board)}", 1
    assert_select "##{ActionView::RecordIdentifier.dom_id(hidden)}", 0
    assert_select "##{ActionView::RecordIdentifier.dom_id(snoozed)}", 0
  end

  test "a session whose snooze has run out is back on the board with nothing having run" do
    expired = make_session(title: "Snooze is over", visibility: SessionVisibility::SNOOZED, snoozed_until: 1.minute.ago)

    get root_path

    assert_response :success
    assert_select "##{ActionView::RecordIdentifier.dom_id(expired)}", 1
    # Reading it did not rewrite it.
    assert_equal SessionVisibility::SNOOZED, expired.reload.visibility
  end

  test "the reveal filter shows the tucked-away sessions and only those" do
    on_board = make_session(title: "On the board")
    hidden = make_session(title: "Tidied away", visibility: SessionVisibility::HIDDEN)

    get root_path, params: { SessionsController::FILTERS_SUBMITTED_PARAM => "1", visibility: "off_board" }

    assert_response :success
    assert_select "##{ActionView::RecordIdentifier.dom_id(hidden)}", 1
    assert_select "##{ActionView::RecordIdentifier.dom_id(on_board)}", 0
  end

  test "the both filter shows everything" do
    on_board = make_session(title: "On the board")
    hidden = make_session(title: "Tidied away", visibility: SessionVisibility::HIDDEN)

    get root_path, params: { SessionsController::FILTERS_SUBMITTED_PARAM => "1", visibility: "all" }

    assert_response :success
    assert_select "##{ActionView::RecordIdentifier.dom_id(on_board)}", 1
    assert_select "##{ActionView::RecordIdentifier.dom_id(hidden)}", 1
  end

  test "the board says how many sessions it is holding back" do
    make_session(title: "Tidied away", visibility: SessionVisibility::HIDDEN)
    make_session(title: "Also tidied", visibility: SessionVisibility::SNOOZED, snoozed_until: 2.days.from_now)

    get root_path

    assert_response :success
    assert_select "#off-board-count", text: /2 sessions tucked away/
  end

  test "the choice persists across a bare visit" do
    hidden = make_session(title: "Tidied away", visibility: SessionVisibility::HIDDEN)

    get root_path, params: { SessionsController::FILTERS_SUBMITTED_PARAM => "1", visibility: "all" }
    assert_response :success

    get root_path

    assert_response :success
    assert_select "##{ActionView::RecordIdentifier.dom_id(hidden)}", 1
  end

  test "a filters cookie written before this control existed falls back to the default board" do
    hidden = make_session(title: "Tidied away", visibility: SessionVisibility::HIDDEN)
    cookies[SessionsController::FILTERS_COOKIE] = { "status" => [ "needs_input" ], "priority_class" => "" }.to_json

    get root_path

    assert_response :success
    assert_select "##{ActionView::RecordIdentifier.dom_id(hidden)}", 0
  end

  test "an unknown visibility filter falls back to the default board" do
    hidden = make_session(title: "Tidied away", visibility: SessionVisibility::HIDDEN)

    get root_path, params: { SessionsController::FILTERS_SUBMITTED_PARAM => "1", visibility: "everything-please" }

    assert_response :success
    assert_select "##{ActionView::RecordIdentifier.dom_id(hidden)}", 0
  end

  # ---- The ranked view -------------------------------------------------------

  test "the ranked view leaves tucked-away rows out and offers the control on the rest" do
    on_board = make_session(title: "Queued work", status: :waiting, scheduling_class: "spot", precedence: 900)
    snoozed = make_session(title: "Snoozed work", status: :waiting, scheduling_class: "spot", precedence: 800,
                           visibility: SessionVisibility::SNOOZED, snoozed_until: 2.days.from_now)

    get root_path, params: { view: SessionsController::VIEW_MODE_RANKED }

    assert_response :success
    assert_select "#ranked_row_#{on_board.id}", 1
    assert_select "#ranked_row_#{snoozed.id}", 0
    # The compact row carries the same snooze/hide affordance the cards do.
    assert_select "#ranked_row_#{on_board.id} [data-controller='visibility']", 1
  end

  test "the ranked view can reveal tucked-away rows" do
    snoozed = make_session(title: "Snoozed work", status: :waiting, scheduling_class: "spot", precedence: 800,
                           visibility: SessionVisibility::SNOOZED, snoozed_until: 2.days.from_now)

    get root_path, params: {
      view: SessionsController::VIEW_MODE_RANKED,
      SessionsController::FILTERS_SUBMITTED_PARAM => "1",
      visibility: "off_board"
    }

    assert_response :success
    assert_select "#ranked_row_#{snoozed.id}", 1
  end

  # ---- The control is on every card ------------------------------------------

  test "every card rendering carries the snooze and hide control" do
    session = make_session(title: "A session")

    [ nil, SessionsController::VIEW_MODE_LAST_TOUCHED, SessionsController::VIEW_MODE_CREATED_DESC ].each do |view|
      get root_path, params: view ? { view: view } : {}

      assert_response :success
      assert_select "##{ActionView::RecordIdentifier.dom_id(session)} [data-controller='visibility']", 1,
        "the #{view || 'categories'} view should offer the visibility control on every card"
    end
  end

  test "a starred card in the pinned group carries the control too" do
    session = make_session(title: "Starred", favorited: true)

    get root_path

    assert_response :success
    assert_select "#pinned_section ##{ActionView::RecordIdentifier.dom_id(session)} [data-controller='visibility']", 1
  end

  test "a card whose session cannot be paused still gets the visibility menu" do
    # An archived session is exactly the case the old overflow menu omitted
    # entirely, because Pause Until had nothing to offer it.
    session = make_session(title: "Trashed", status: :archived)
    assert_not session.pausable_until?

    get root_path, params: { SessionsController::FILTERS_SUBMITTED_PARAM => "1", status: [ "archived" ] }

    assert_response :success
    assert_select "##{ActionView::RecordIdentifier.dom_id(session)} [data-controller='visibility']", 1
  end

  test "the detail page and its mobile sheet both offer the control" do
    session = make_session(title: "A session")

    get session_path(session)

    assert_response :success
    assert_select "[data-controller='visibility']", minimum: 2
  end
end
