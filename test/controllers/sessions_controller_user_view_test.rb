require "test_helper"
require "mocha/minitest"

# The dashboard's User view (`/?view=user`) — the decision board.
#
# What is asserted here is the four things the view promises: it shows every
# session the filters match, it orders them priority-above-spot then by
# precedence, it puts the decision on the row (PR, Merge, Snooze, Trash), and the
# two buttons at the top and on the row do what they say.
class SessionsControllerUserViewTest < ActionDispatch::IntegrationTest
  DESKTOP_UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36".freeze
  GREEN_PR = "https://github.com/o/r/pull/42".freeze

  def setup
    Session.any_instance.stubs(:broadcast_status_change)
    Session.any_instance.stubs(:broadcast_update_to_sessions_index)
    Session.any_instance.stubs(:broadcast_create_to_sessions_index)
    Session.any_instance.stubs(:broadcast_remove_from_sessions_index)

    McpOauthPendingFlow.delete_all
    Notification.delete_all
    Log.delete_all
    EnqueuedMessage.delete_all
    Session.delete_all
    Category.delete_all
    AppSetting.delete_all
    Trigger.where(name: Sessions::DashboardReprioritizer::TRIGGER_NAME).destroy_all
  end

  def make_session(status: :needs_input, klass: SessionGenesis::SPOT, precedence: 0, title: "A session", custom_metadata: {})
    Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "p",
      title: title,
      status: status,
      scheduling_class: klass,
      precedence: precedence,
      custom_metadata: custom_metadata
    )
  end

  def green_pr_metadata(url = GREEN_PR)
    {
      "github_pull_request_urls" => [ url ],
      "github_pull_request_statuses" => { url => "open" },
      "github_pull_request_ci_statuses" => { url => "pass" }
    }
  end

  # Row ids in document order.
  def row_ids
    css_select("#user_view_list li[id^='user_view_row_']").map { |el| el["id"] }
  end

  def get_board(**params)
    get root_path(**params.merge(view: "user")), headers: { "User-Agent" => DESKTOP_UA }
  end

  # ---- Ordering --------------------------------------------------------------

  test "one unified list, priority above spot, precedence within each" do
    low_priority = make_session(klass: SessionGenesis::PRIORITY, precedence: 1, title: "priority low")
    high_priority = make_session(klass: SessionGenesis::PRIORITY, precedence: 900, title: "priority high")
    high_spot = make_session(klass: SessionGenesis::SPOT, precedence: 100_000, title: "spot high")
    low_spot = make_session(klass: SessionGenesis::SPOT, precedence: 5, title: "spot low")

    get_board

    assert_response :success
    assert_equal [
      "user_view_row_#{high_priority.id}",
      "user_view_row_#{low_priority.id}",
      "user_view_row_#{high_spot.id}",
      "user_view_row_#{low_spot.id}"
    ], row_ids, "a spot session cannot outrank a priority one however high its precedence"

    # And it really is one list, not the Ranked view's two sections.
    assert_select "#ranked_priority_list", false
    assert_select "#ranked_spot_list", false
  end

  test "every row carries a priority or spot badge, since the list is not split" do
    priority = make_session(klass: SessionGenesis::PRIORITY)
    spot = make_session(klass: SessionGenesis::SPOT)

    get_board

    assert_select "#user_view_row_#{priority.id}", text: /Priority/
    assert_select "#user_view_row_#{spot.id}", text: /Spot/
  end

  # ---- Filters ---------------------------------------------------------------

  test "the board opens on needs_input, the sessions actually waiting on a human" do
    parked = make_session(status: :needs_input)
    running = make_session(status: :running)

    get_board

    assert_equal [ "user_view_row_#{parked.id}" ], row_ids
    assert_select "#user_view_row_#{running.id}", false
  end

  test "the board follows an explicit status filter" do
    parked = make_session(status: :needs_input)
    failed = make_session(status: :failed)

    get_board(filters: "1", status: %w[failed])

    assert_equal [ "user_view_row_#{failed.id}" ], row_ids
    assert_select "#user_view_row_#{parked.id}", false
  end

  test "a search narrows the board in place rather than replacing it" do
    wanted = make_session(title: "fix the widget")
    other = make_session(title: "something else")

    get_board(q: "widget")

    assert_select "#user_view_list", true, "a search must not bounce the operator out of the board"
    assert_equal [ "user_view_row_#{wanted.id}" ], row_ids
    assert_select "#user_view_row_#{other.id}", false
  end

  test "a hidden session is off the board and back on it when hidden ones are revealed" do
    hidden = make_session
    hidden.update!(visibility: SessionVisibility::HIDDEN)

    get_board
    assert_select "#user_view_row_#{hidden.id}", false

    get_board(filters: "1", status: %w[needs_input], visibility: SessionVisibility::FILTER_ALL)
    assert_select "#user_view_row_#{hidden.id}", true
  end

  test "an empty board still renders the list, so a restored row has somewhere to land" do
    get_board

    assert_response :success
    assert_select "#user_view_list", true
    assert_select "[data-user-view-target='empty']", text: /No sessions match these filters/
  end

  # ---- What a row shows ------------------------------------------------------

  test "a row shows the agent root and the generated status summary inline" do
    session = make_session
    session.update!(metadata: (session.metadata || {}).merge("agent_root_key" => "zimmer"))
    SessionStatusSummary.create!(session: session, state: "ready",
      summary: "Holding PR 42 for a merge decision.", transcript_line_count: session.transcript_line_count)

    get_board

    assert_select "#user_view_row_#{session.id}", text: /zimmer/
    assert_select "#user_view_row_#{session.id}", text: /Holding PR 42 for a merge decision/
  end

  test "a row with no summary says so rather than rendering an empty gap" do
    make_session

    get_board

    assert_select "#user_view_list", text: /No status summary yet/
  end

  test "a stale summary says how far behind it is" do
    session = make_session
    SessionStatusSummary.create!(session: session, state: "ready", summary: "Older news.",
      transcript_line_count: 0)
    # Staleness is counted in transcript LINES, not in time — and the count is read
    # through ChunkedTranscript, which only trusts the column once the session's
    # transcript is actually chunked.
    session.update_columns(transcript_line_count: 4, transcript_byte_size: 120)

    get_board

    assert_select "#user_view_list", text: /4 messages since this was written/
  end

  # ---- The Merge button ------------------------------------------------------

  test "Merge is offered on an open, CI-green PR" do
    session = make_session(custom_metadata: green_pr_metadata)

    get_board

    assert_select "#user_view_merge_#{session.id} form[action=?]", authorize_merge_session_path(session)
  end

  test "Merge is not offered when CI is not green" do
    session = make_session(custom_metadata: green_pr_metadata.merge(
      "github_pull_request_ci_statuses" => { GREEN_PR => "pending" }
    ))

    get_board

    assert_select "#user_view_merge_#{session.id} form", false
    assert_select "#user_view_merge_#{session.id}", text: ""
  end

  test "a merged PR shows Merged instead of a button" do
    session = make_session(custom_metadata: green_pr_metadata.merge(
      "github_pull_request_statuses" => { GREEN_PR => "merged" }
    ))

    get_board

    assert_select "#user_view_merge_#{session.id}", text: /Merged/
    assert_select "#user_view_merge_#{session.id} form", false
  end

  test "clicking Merge sends the session the authorization and records a human message" do
    session = make_session(status: :running, custom_metadata: green_pr_metadata)

    post authorize_merge_session_path(session), as: :turbo_stream

    assert_response :success
    queued = session.enqueued_messages.pending.last
    assert AutomatedPrompts.merge_authorization?(queued.content), "the message must carry the authorization marker"
    assert_includes queued.content, GREEN_PR
    assert HumanMessage.where(session_id: session.id)
      .where("provenance->>'entry_point' = ?", "web_ui.authorize_merge").exists?,
      "the click is a human's, and the provenance has to say so"
  end

  test "clicking Merge twice sends one message and reports the second as already sent" do
    session = make_session(status: :running, custom_metadata: green_pr_metadata)

    post authorize_merge_session_path(session), as: :turbo_stream
    post authorize_merge_session_path(session), as: :turbo_stream

    assert_response :success
    assert_equal 1, session.enqueued_messages.count
    assert_equal 1, HumanMessage.where(session_id: session.id)
      .where("provenance->>'entry_point' = ?", "web_ui.authorize_merge").count
  end

  test "the button re-renders as sent, so the board says what the click did" do
    session = make_session(status: :running, custom_metadata: green_pr_metadata)

    post authorize_merge_session_path(session), as: :turbo_stream

    assert_match(/user_view_merge_#{session.id}/, response.body)
    assert_match(/Merge sent/, response.body)
  end

  test "Merge on a PR that is not green is refused and sends nothing" do
    session = make_session(status: :running, custom_metadata: green_pr_metadata.merge(
      "github_pull_request_ci_statuses" => { GREEN_PR => "fail" }
    ))

    post authorize_merge_session_path(session), as: :turbo_stream

    assert_response :success
    assert_equal 0, session.enqueued_messages.count
    assert_equal 0, HumanMessage.where(session_id: session.id)
      .where("provenance->>'entry_point' = ?", "web_ui.authorize_merge").count
  end

  # ---- Trash -----------------------------------------------------------------

  test "Trash archives the session and streams the row's removal" do
    session = make_session

    post archive_session_path(session), as: :turbo_stream

    assert_response :success
    assert_equal "archived", session.reload.status
    assert_match(/user_view_row_#{session.id}/, response.body)
    assert_match(/turbo-stream action="remove"/, response.body)
  end

  # The speed bump is the reason the removal is server-driven rather than
  # optimistic: this click does NOT archive, so a row the browser had already
  # taken away would have lied.
  test "Trash over a queued message refuses, and streams no row removal" do
    session = make_session
    session.enqueued_messages.create!(content: "still to deliver", position: 1, status: "pending")

    post archive_session_path(session), as: :turbo_stream

    assert_equal "needs_input", session.reload.status
    assert_no_match(/turbo-stream action="remove"/, response.body)
  end

  # ---- Reprioritize ----------------------------------------------------------

  test "the board carries a Reprioritize button" do
    make_session

    get_board

    assert_select "#user_view_reprioritize form[action=?]", reprioritize_sessions_path
  end

  test "Reprioritize starts the durable session and names it back" do
    post reprioritize_sessions_path, as: :turbo_stream

    assert_response :success
    trigger = Trigger.find_by(name: Sessions::DashboardReprioritizer::TRIGGER_NAME)
    assert trigger.present?, "the trigger is seeded on first press"
    assert trigger.last_session_id.present?, "the trigger points at the session it started"
    assert_match(/user_view_reprioritize/, response.body)
    assert_match(/session ##{trigger.last_session_id}/, response.body)
  end

  test "pressing Reprioritize twice reuses one session rather than spawning two" do
    post reprioritize_sessions_path, as: :turbo_stream
    trigger = Trigger.find_by(name: Sessions::DashboardReprioritizer::TRIGGER_NAME)
    first_session_id = trigger.last_session_id
    Session.find(first_session_id).update!(status: :needs_input)
    Session.any_instance.stubs(:deliver_follow_up!)

    post reprioritize_sessions_path, as: :turbo_stream

    assert_equal first_session_id, trigger.reload.last_session_id
  end

  # ---- Scale -----------------------------------------------------------------

  # There is no paginator on purpose — a drag between two rows means nothing if
  # one of them is on another page — so the list is capped and says when it has
  # truncated. Asserted against the constant rather than by making 500 rows.
  test "the cap the view renders under is the cap the reorder tool writes under" do
    assert_equal SessionsController::USER_VIEW_LIMIT, Sessions::ApplyUserViewOrder::MAX_IDS,
      "the reorder tool and the view have to agree on how big a board can get"
    assert_equal SessionsController::USER_VIEW_LIMIT, Mcp::Tools::GetUserView::MAX_ROWS,
      "an agent paging to the end of get_user_view has to have seen exactly the board"
  end

  test "the board renders everything the filters match, with no paginator" do
    sessions = 60.times.map { |i| make_session(precedence: i, title: "row #{i}") }

    get_board

    assert_equal sessions.size, row_ids.size,
      "the board shows every matching session — SESSIONS_PER_PAGE does not apply here"
    assert_select "#user_view_list nav.pagination", false
  end
end
