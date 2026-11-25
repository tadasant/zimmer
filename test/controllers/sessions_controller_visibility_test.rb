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
    AppSetting.delete_all
  end

  # The dashboard's default view is Your board, whose rows wrap a card and carry
  # their own id — see SessionsHelper#board_v2_row_dom_id.
  def board_row(session)
    "#board_v2_row_#{session.id}"
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
      branch: "main"
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

    get dashboard_board_path

    assert_response :success
    assert_select board_row(on_board), 1
    assert_select board_row(hidden), 0
    assert_select board_row(snoozed), 0
  end

  test "a session whose snooze has run out is back on the board with nothing having run" do
    expired = make_session(title: "Snooze is over", visibility: SessionVisibility::SNOOZED, snoozed_until: 1.minute.ago)

    get dashboard_board_path

    assert_response :success
    assert_select board_row(expired), 1
    # Reading it did not rewrite it.
    assert_equal SessionVisibility::SNOOZED, expired.reload.visibility
  end

  test "the reveal filter shows the tucked-away sessions and only those" do
    on_board = make_session(title: "On the board")
    hidden = make_session(title: "Tidied away", visibility: SessionVisibility::HIDDEN)

    get dashboard_board_path, params: { SessionsController::FILTERS_SUBMITTED_PARAM => "1", visibility: "off_board" }

    assert_response :success
    assert_select board_row(hidden), 1
    assert_select board_row(on_board), 0
  end

  # Would have caught a badge that raises on the row shape it is asked to render.
  test "a revealed card renders its badge and a way back" do
    hidden = make_session(title: "Tidied away", visibility: SessionVisibility::HIDDEN)
    snoozed = make_session(title: "Back on Friday", visibility: SessionVisibility::SNOOZED,
                           snoozed_until: 3.days.from_now)

    get dashboard_board_path, params: { SessionsController::FILTERS_SUBMITTED_PARAM => "1", visibility: "off_board" }

    assert_response :success
    assert_select board_row(hidden), text: /Hidden/
    assert_select board_row(snoozed), text: /Snoozed/
    assert_select "#{board_row(hidden)} [data-action='visibility#restore']",
      minimum: 1, message: "a tucked-away row must offer a way back"
  end

  # The badge and the menu must survive a row written before snoozed_until became
  # required, rather than 500ing the whole revealed board.
  test "a legacy snoozed row with no end time still renders" do
    legacy = make_session(title: "Legacy snooze")
    legacy.update_columns(visibility: SessionVisibility::SNOOZED, snoozed_until: nil)

    get dashboard_board_path, params: { SessionsController::FILTERS_SUBMITTED_PARAM => "1", visibility: "off_board" }

    assert_response :success
    assert_select board_row(legacy), text: /Snoozed/
  end

  test "the all filter shows everything" do
    on_board = make_session(title: "On the board")
    hidden = make_session(title: "Tidied away", visibility: SessionVisibility::HIDDEN)
    backlogged = make_session(title: "Parked", visibility: SessionVisibility::BACKLOGGED)

    get dashboard_board_path, params: { SessionsController::FILTERS_SUBMITTED_PARAM => "1", visibility: "all" }

    assert_response :success
    assert_select board_row(on_board), 1
    assert_select board_row(hidden), 1
    assert_select board_row(backlogged), 1
  end

  # ---- The backlog -----------------------------------------------------------

  test "backlogs a session and answers with the board state" do
    session = make_session(status: :waiting, scheduling_class: "spot", precedence: 777)

    patch update_visibility_session_path(session),
      params: { visibility: "backlogged" }.to_json,
      headers: { "Content-Type" => "application/json", "Accept" => "application/json" }

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "backlogged", body["visibility"]
    assert_equal false, body["board_visible"]
    session.reload
    assert_equal SessionVisibility::BACKLOGGED, session.visibility
    assert_nil session.snoozed_until
    # Presentation only: nothing the scheduler reads moved.
    assert_equal "waiting", session.status
    assert_equal "spot", session.scheduling_class
    assert_equal 777, session.precedence
  end

  test "the backlog is off the default board and out of Snoozed & hidden" do
    on_board = make_session(title: "On the board")
    hidden = make_session(title: "Tidied away", visibility: SessionVisibility::HIDDEN)
    backlogged = make_session(title: "Parked", visibility: SessionVisibility::BACKLOGGED)

    get dashboard_board_path
    assert_select board_row(on_board), 1
    assert_select board_row(backlogged), 0

    get dashboard_board_path, params: { SessionsController::FILTERS_SUBMITTED_PARAM => "1", visibility: "off_board" }
    assert_select board_row(hidden), 1
    assert_select board_row(backlogged), 0
  end

  test "the backlogged filter shows the backlog and only that, with a badge and a way back" do
    on_board = make_session(title: "On the board")
    hidden = make_session(title: "Tidied away", visibility: SessionVisibility::HIDDEN)
    backlogged = make_session(title: "Parked", visibility: SessionVisibility::BACKLOGGED)

    get dashboard_board_path, params: { SessionsController::FILTERS_SUBMITTED_PARAM => "1", visibility: "backlogged" }

    assert_response :success
    assert_select board_row(backlogged), 1
    assert_select board_row(backlogged), text: /Backlog/
    assert_select "#{board_row(backlogged)} [data-action='visibility#restore']", minimum: 1
    assert_select "#{board_row(backlogged)} [data-action='visibility#backlog']", 0,
      "an already-backlogged row is not offered the backlog again"
    assert_select board_row(on_board), 0
    assert_select board_row(hidden), 0
  end

  test "the board counts the backlog apart from the tucked-away sessions" do
    make_session(title: "Tidied away", visibility: SessionVisibility::HIDDEN)
    make_session(title: "Parked", visibility: SessionVisibility::BACKLOGGED)
    make_session(title: "Also parked", visibility: SessionVisibility::BACKLOGGED)

    get dashboard_board_path

    assert_select "turbo-stream[action=update][target=off-board-count] template",
      text: /1 session tucked away · 2 backlogged/
  end

  test "the Filters section offers the four board-visibility options" do
    get root_path

    assert_response :success
    %w[on_board off_board backlogged all].each do |value|
      assert_select "input[type=radio][name=visibility][value=#{value}]", 1
    end
    assert_select "label[for=visibility-filter-backlogged]", text: /Backlogged/
    assert_select "label[for=visibility-filter-all]", text: /All/
  end

  test "the board says how many sessions it is holding back" do
    make_session(title: "Tidied away", visibility: SessionVisibility::HIDDEN)
    make_session(title: "Also tidied", visibility: SessionVisibility::SNOOZED, snoozed_until: 2.days.from_now)

    get dashboard_board_path

    assert_response :success
    # The count rides in the board as a stream onto the shell's Filters legend.
    assert_select "turbo-stream[action=update][target=off-board-count] template", text: /2 sessions tucked away/
  end

  # The count is the nudge to reveal, so it has to name sessions revealing would
  # actually produce — not every tucked-away row in the table.
  test "the tucked-away count is narrowed by the other filters too" do
    make_session(title: "Tidied away", visibility: SessionVisibility::HIDDEN, status: :needs_input)
    make_session(title: "Also tidied", visibility: SessionVisibility::HIDDEN, status: :failed)

    get dashboard_board_path, params: { SessionsController::FILTERS_SUBMITTED_PARAM => "1", status: [ "needs_input" ] }

    assert_response :success
    # The count rides in the board as a stream onto the shell's Filters legend.
    assert_select "turbo-stream[action=update][target=off-board-count] template", text: /1 session tucked away/
  end

  test "the choice persists across a bare visit" do
    hidden = make_session(title: "Tidied away", visibility: SessionVisibility::HIDDEN)

    get root_path, params: { SessionsController::FILTERS_SUBMITTED_PARAM => "1", visibility: "all" }
    assert_response :success

    get dashboard_board_path

    assert_response :success
    assert_select board_row(hidden), 1
  end

  # An open page asks for its board again on its own, with the filters it was opened
  # with. That shapes the one response. It is not a choice about the next visit.
  test "a board fetch or a backfill does not change which visibilities the next bare visit shows" do
    on_board = make_session(title: "Left in plain sight")
    off_board = [
      make_session(title: "Quetzal one", visibility: SessionVisibility::HIDDEN),
      make_session(title: "Quetzal two", visibility: SessionVisibility::SNOOZED, snoozed_until: 2.days.from_now),
      make_session(title: "Quetzal three", visibility: SessionVisibility::BACKLOGGED)
    ]
    SessionsController::VALID_VIEW_MODES.product(%w[all off_board backlogged]).each do |view, visibility|
      filters = { view: view, SessionsController::FILTERS_SUBMITTED_PARAM => "1", visibility: visibility }

      get dashboard_board_path, params: filters
      assert_response :success
      assert_nil cookies[SessionsController::FILTERS_COOKIE].presence, "the #{view} board, showing #{visibility}"

      get root_path, params: filters, headers: { "X-Zimmer-Backfill" => "1" }
      assert_response :success
      assert_nil cookies[SessionsController::FILTERS_COOKIE].presence, "the #{view} backfill, showing #{visibility}"
    end

    SessionsController::VALID_VIEW_MODES.each do |view|
      get dashboard_board_path, params: { view: view }
      assert_response :success
      assert_match on_board.title, response.body, "on the #{view} board"
      off_board.each { |session| assert_no_match(/#{session.title}/, response.body, "on the #{view} board") }
    end
  end

  test "a filters cookie written before this control existed falls back to the default board" do
    hidden = make_session(title: "Tidied away", visibility: SessionVisibility::HIDDEN)
    cookies[SessionsController::FILTERS_COOKIE] = { "status" => [ "needs_input" ], "priority_class" => "" }.to_json

    get root_path

    assert_response :success
    assert_select board_row(hidden), 0
  end

  test "an unknown visibility filter falls back to the default board" do
    hidden = make_session(title: "Tidied away", visibility: SessionVisibility::HIDDEN)

    get root_path, params: { SessionsController::FILTERS_SUBMITTED_PARAM => "1", visibility: "everything-please" }

    assert_response :success
    assert_select board_row(hidden), 0
  end

  # ---- The ranked view -------------------------------------------------------

  test "the ranked view leaves tucked-away rows out and offers the control on the rest" do
    on_board = make_session(title: "Queued work", status: :waiting, scheduling_class: "spot", precedence: 900)
    snoozed = make_session(title: "Snoozed work", status: :waiting, scheduling_class: "spot", precedence: 800,
                           visibility: SessionVisibility::SNOOZED, snoozed_until: 2.days.from_now)

    get dashboard_board_path, params: { view: SessionsController::VIEW_MODE_RANKED }

    assert_response :success
    assert_select "#ranked_row_#{on_board.id}", 1
    assert_select "#ranked_row_#{snoozed.id}", 0
    # The compact row carries the same snooze/hide affordance the cards do.
    assert_select "#ranked_row_#{on_board.id} [data-controller='visibility']", 1
  end

  test "the ranked view can reveal tucked-away rows" do
    snoozed = make_session(title: "Snoozed work", status: :waiting, scheduling_class: "spot", precedence: 800,
                           visibility: SessionVisibility::SNOOZED, snoozed_until: 2.days.from_now)

    get dashboard_board_path, params: {
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

    [ SessionsController::VIEW_MODE_LAST_TOUCHED, SessionsController::VIEW_MODE_CREATED_DESC ].each do |view|
      get dashboard_board_path, params: { view: view }

      assert_response :success
      assert_select "##{ActionView::RecordIdentifier.dom_id(session)} [data-controller='visibility']", 1,
        "the #{view} view should offer the visibility control on every card"
    end
  end

  # Your board's card carries the control, as every card does.
  test "Your board's card carries the control" do
    session = make_session(title: "A session")

    get dashboard_board_path, params: { view: SessionsController::VIEW_MODE_BOARD_V2 }

    assert_response :success
    assert_select "#{board_row(session)} [data-controller='visibility']", 1
  end

  test "a row whose session cannot be slept still gets the visibility menu" do
    # An archived session cannot be slept at all, and its row still has to carry
    # the menu: board visibility is offered in every state.
    session = make_session(title: "Trashed", status: :archived)
    assert_not session.sleepable?

    get dashboard_board_path, params: { SessionsController::FILTERS_SUBMITTED_PARAM => "1", status: [ "archived" ] }

    assert_response :success
    assert_select "#{board_row(session)} [data-controller='visibility']", 1
  end

  test "the detail page and its mobile sheet both offer the control" do
    session = make_session(title: "A session")

    get session_path(session)

    assert_response :success
    assert_select "[data-controller='visibility']", minimum: 2
  end
end
