# frozen_string_literal: true

require "test_helper"

# The Ranked view and the writes it makes: the queue screen where spot work is
# ordered, and priority work is demoted into it.
class SessionsControllerRankedViewTest < ActionDispatch::IntegrationTest
  def spot(precedence, title: "spot #{precedence}", status: :waiting)
    Session.create!(git_root: "https://github.com/t/r.git", prompt: "x", title: title,
      status: status, scheduling_class: SessionGenesis::SPOT, precedence: precedence)
  end

  def priority(precedence: 0, title: "priority")
    Session.create!(git_root: "https://github.com/t/r.git", prompt: "x", title: title,
      status: :waiting, scheduling_class: SessionGenesis::PRIORITY, precedence: precedence)
  end

  # Where each session's row appears in the rendered page, so ordering can be
  # asserted without reaching into controller internals.
  def row_position(session)
    response.body.index("ranked_row_#{session.id}\"")
  end

  def spot_row_ids
    response.body.scan(/data-ranked-queue-target="spotList".*?<\/ul>/m).first.to_s
      .scan(/ranked_row_(\d+)"/).flatten.map(&:to_i)
  end

  def priority_row_ids
    response.body.scan(/data-ranked-queue-target="priorityList".*?<\/ul>/m).first.to_s
      .scan(/ranked_row_(\d+)"/).flatten.map(&:to_i)
  end

  # --- the view ---------------------------------------------------------------

  test "the ranked view lists spot sessions highest precedence first" do
    low = spot(10)
    high = spot(900)

    get root_url(view: SessionsController::VIEW_MODE_RANKED, filters: "1", status: [ "waiting" ])

    assert_response :success
    assert_equal [ high.id, low.id ], spot_row_ids
  end

  test "the ranked view splits priority sessions out above the queue" do
    queued = spot(10)
    top = priority

    get root_url(view: SessionsController::VIEW_MODE_RANKED, filters: "1", status: [ "waiting" ])

    assert_includes priority_row_ids, top.id
    assert_not_includes spot_row_ids, top.id
    assert_includes spot_row_ids, queued.id
  end

  # The dashboard's default is `needs_input`, which would show an empty queue on
  # a screen whose whole subject is work that has not started.
  test "the ranked view defaults to showing unstarted work" do
    queued = spot(10)

    get root_url(view: SessionsController::VIEW_MODE_RANKED)

    assert_includes spot_row_ids, queued.id,
      "a `waiting` session must be visible without the user choosing a filter first"
  end

  test "an explicitly chosen status filter still wins in the ranked view" do
    spot(10)

    get root_url(view: SessionsController::VIEW_MODE_RANKED, filters: "1", status: [ "needs_input" ])

    assert_empty spot_row_ids
    assert_includes response.body, "No spot sessions match these filters"
  end

  # --- quick filters ----------------------------------------------------------

  test "the All Unarchived quick filter shows live work and hides the trash" do
    live = spot(10, title: "live spot")
    trashed = spot(11, title: "trashed spot", status: :archived)

    get root_url(view: SessionsController::VIEW_MODE_RANKED, filters: "1",
      status: SessionsController::UNARCHIVED_STATUSES)

    assert_response :success
    assert_includes spot_row_ids, live.id
    assert_not_includes spot_row_ids, trashed.id
  end

  test "the All Priority Unarchived quick filter drops the spot queue entirely" do
    queued = spot(10)
    top = priority

    get root_url(view: SessionsController::VIEW_MODE_RANKED, filters: "1",
      status: SessionsController::UNARCHIVED_STATUSES, priority_class: SessionGenesis::PRIORITY)

    assert_includes priority_row_ids, top.id
    assert_not_includes spot_row_ids, queued.id
  end

  test "the All quick filter shows the trash too" do
    trashed = spot(11, title: "trashed spot", status: :archived)

    get root_url(view: SessionsController::VIEW_MODE_RANKED, filters: "1")

    assert_includes spot_row_ids, trashed.id, "no status ticked is every status"
  end

  test "a quick filter is persisted the way an Apply is" do
    get root_url(filters: "1", status: SessionsController::UNARCHIVED_STATUSES)
    assert_response :success

    # A bare visit afterwards keeps the choice rather than snapping back to the
    # needs_input default.
    live = spot(10, title: "live spot")
    get root_url(view: SessionsController::VIEW_MODE_RANKED)

    assert_includes spot_row_ids, live.id
  end

  # --- staying live -----------------------------------------------------------

  # The card grid's broadcast replaces `dom_id(session)` with a session card. A
  # ranked row is neither, so it was never a target of it — which is the whole
  # reason the queue went stale. These pin the two ends of the replacement: the
  # page subscribes, and the model publishes something the page has an element for.

  test "the ranked view subscribes to the ranked stream and ids every row's status pill" do
    session = spot(10)

    get root_url(view: SessionsController::VIEW_MODE_RANKED)

    assert_response :success
    assert_select "turbo-cable-stream-source[signed-stream-name=?]",
      Turbo::StreamsChannel.signed_stream_name(Session::RANKED_STREAM)
    assert_select "##{"ranked_row_status_#{session.id}"}", text: "Waiting"
  end

  test "a status change broadcasts just the row's status pill" do
    session = spot(10)

    streams = capture_turbo_stream_broadcasts(Session::RANKED_STREAM) do
      session.update!(status: :running)
    end

    assert_equal 1, streams.size
    assert_equal "replace", streams.first["action"]
    assert_equal "ranked_row_status_#{session.id}", streams.first["target"]
    assert_includes streams.first.to_s, "Running"
  end

  test "trashing a session removes its row from the queue rather than restyling it" do
    session = spot(10)

    streams = capture_turbo_stream_broadcasts(Session::RANKED_STREAM) do
      session.update!(status: :archived)
    end

    assert_equal 1, streams.size
    assert_equal "remove", streams.first["action"]
    assert_equal "ranked_row_#{session.id}", streams.first["target"]
  end

  # A rank edit is not a status change, and a broadcast landing on a row whose
  # number the user is mid-way through typing is exactly what this view cannot
  # afford. Nothing but a status change reaches the queue.
  test "a precedence write broadcasts nothing to the ranked stream" do
    session = spot(10)

    streams = capture_turbo_stream_broadcasts(Session::RANKED_STREAM) do
      patch update_precedence_session_url(session), params: { precedence: 640 }, as: :json
    end

    assert_response :success
    assert_empty streams
  end

  # A broadcast is fire-and-forget: a page whose socket died missed every update
  # sent while it was away, and re-subscribing cannot replay them. The dashboard
  # already reconciles against a fresh render on reconnect — but only for regions
  # marked `data-live-region`, and a region it cannot find is silently reported as
  # clean. Unmarked, the ranked view would come back from an iOS PWA suspend just
  # as stale as before this change, with nothing reporting a problem.
  test "the ranked lists are live regions, so a page that missed broadcasts recovers them" do
    spot(10)

    get root_url(view: SessionsController::VIEW_MODE_RANKED)

    # `sync` rather than `replace`: rows are added, swapped AND removed here, and
    # it reconciles children by id, which is what the rows carry.
    assert_select "ul#ranked_spot_list[data-live-region=?]", "sync"
    assert_select "ul#ranked_priority_list[data-live-region=?]", "sync"
    # backfillLiveRegions only walks `[data-live-region][id]`, so the id is not
    # decoration.
    assert_select "[data-live-region]:not([id])", false,
      "a live region without an id is skipped by the backfill"
  end

  # --- the row's actions ------------------------------------------------------

  test "promote and demote are rendered inside the row's overflow menu, not on the row" do
    queued = spot(10)
    top = priority

    get root_url(view: SessionsController::VIEW_MODE_RANKED)

    assert_select "#ranked_row_#{top.id} [data-controller='overflow-menu'] button[data-ranked-queue-target='demoteAction']"
    assert_select "#ranked_row_#{queued.id} [data-controller='overflow-menu'] button[data-ranked-queue-target='promoteAction']"

    # Both entries ride on every row, one of them hidden, so a promote or a demote
    # can swap them in place without a reload.
    assert_select "#ranked_row_#{top.id} button[data-ranked-queue-target='promoteAction'].hidden"
    assert_select "#ranked_row_#{queued.id} button[data-ranked-queue-target='demoteAction'].hidden"

    assert_select "#ranked_row_#{top.id} button[aria-expanded='false'][aria-haspopup='true']"
  end

  test "the menu also offers Start now and Trash" do
    queued = spot(10)

    get root_url(view: SessionsController::VIEW_MODE_RANKED)

    assert_select "#ranked_row_#{queued.id} [role='menu'] a[href=?][data-turbo-method='post']",
      start_now_session_path(queued), text: "Start now"
    # The same #archive every other Trash affordance posts to, so the queued-message
    # speed bump and the Undo toast come with it rather than being reimplemented.
    assert_select "#ranked_row_#{queued.id} [role='menu'] a[href=?][data-turbo-method='post']",
      archive_session_path(queued), text: "Trash"
  end

  # The title is the reading surface of the row, and clicking it should not take
  # the operator off the queue. It stays a real <a href> so middle-click and
  # ⌘/Ctrl-click keep opening a new tab — session-drawer#open intercepts only the
  # plain left click, exactly as the card grid's View button does.
  test "the row's title is a real link wired to the session drawer" do
    queued = spot(10, title: "Rebuild the AIR catalog index")

    get root_url(view: SessionsController::VIEW_MODE_RANKED)

    assert_select "#ranked_row_#{queued.id} a[href=?]", session_path(queued) do |links|
      title_link = links.find { |link| link.text.include?("Rebuild the AIR catalog index") }
      assert title_link, "the title should still be a link to the session"
      assert_equal "click->session-drawer#open", title_link["data-action"]
      assert_equal "_top", title_link["data-turbo-frame"], "the no-JS fallback is a full-page visit"
      # Turbo 8 would otherwise prefetch the FRAMELESS response for this URL on
      # hover and serve it to the drawer's frame request, which renders
      # "Content missing".
      assert_equal "false", title_link["data-turbo-prefetch"]
    end
  end

  # --- starting a row ---------------------------------------------------------

  test "start_now gives a session that never ran its first turn" do
    session = spot(10)

    assert_enqueued_with(job: AgentSessionJob, args: [ session.id ]) do
      post start_now_session_path(session)
    end

    assert_redirected_to session_path(session)
    assert_match(/starting now/i, flash[:notice])
  end

  test "start_now says why it will not start a session that is already running" do
    session = spot(10, status: :running)

    assert_no_enqueued_jobs(only: AgentSessionJob) do
      post start_now_session_path(session)
    end

    assert_match(/only a waiting session/, flash[:alert])
  end

  # The complaint this answers: promoting a held session removed the reason it
  # was held and changed nothing about when it would next be asked, so it went on
  # waiting out a re-check up to an hour away.
  test "promoting a waiting session starts it" do
    session = spot(10)

    assert_enqueued_with(job: AgentSessionJob, args: [ session.id ]) do
      patch update_scheduling_class_session_url(session),
        params: { scheduling_class: SessionGenesis::PRIORITY }, as: :json
    end

    assert_response :success
    assert_equal "started", response.parsed_body["start_outcome"]
    assert session.logs.reload.any? { |log| log.content.include?("Started now") }
  end

  test "demoting a session starts nothing" do
    session = priority

    assert_no_enqueued_jobs(only: AgentSessionJob) do
      patch update_scheduling_class_session_url(session),
        params: { scheduling_class: SessionGenesis::SPOT, place: "top_of_spot" }, as: :json
    end

    assert_response :success
    assert_nil response.parsed_body["start_outcome"]
  end

  # A session that has run before and has nothing queued is stranded rather than
  # held, so there is no turn to bring forward. A promote leaves it alone; only
  # an explicit Start nudges it, which is what Refresh already does for it.
  test "promoting a session with nothing queued reports no start" do
    session = spot(10)
    session.update!(session_id: "cli-abc")

    patch update_scheduling_class_session_url(session),
      params: { scheduling_class: SessionGenesis::PRIORITY }, as: :json

    assert_response :success
    assert_nil response.parsed_body["start_outcome"]
  end

  # --- editing a rank ---------------------------------------------------------

  test "update_precedence sets the value and answers with JSON for the ranked view" do
    session = spot(10)

    patch update_precedence_session_url(session), params: { precedence: 640 }, as: :json

    assert_response :success
    assert_equal 640, session.reload.precedence
    assert_equal 640, response.parsed_body["precedence"]
  end

  test "update_precedence records the change in the session log" do
    session = spot(10)

    patch update_precedence_session_url(session), params: { precedence: 55 }

    assert_includes session.logs.reload.map(&:content).join, "Precedence set to 55 (was 10)"
  end

  test "update_precedence rejects a value outside the accepted range" do
    session = spot(10)

    patch update_precedence_session_url(session),
      params: { precedence: SessionPrecedence::MAX + 1 }, as: :json

    assert_response :unprocessable_entity
    assert_equal 10, session.reload.precedence
  end

  # --- dragging ---------------------------------------------------------------

  test "reorder_precedence takes the midpoint of the two rows it was dropped between" do
    above = spot(100)
    below = spot(50)
    moved = spot(1)

    patch reorder_precedence_session_url(moved),
      params: { above_id: above.id, below_id: below.id }, as: :json

    assert_response :success
    assert_equal 75, moved.reload.precedence
    assert_equal 75, response.parsed_body["precedence"]
  end

  test "reorder_precedence nudges adjacent neighbours apart and reports every change" do
    above = spot(21)
    below = spot(20)
    moved = spot(1)

    patch reorder_precedence_session_url(moved),
      params: { above_id: above.id, below_id: below.id }, as: :json

    assert_response :success
    assert_equal 22, above.reload.precedence
    assert_equal 19, below.reload.precedence

    changed = response.parsed_body["changes"].to_h { |c| [ c["id"], c["precedence"] ] }
    assert_equal 22, changed[above.id]
    assert_equal 19, changed[below.id]
  end

  test "a demotion does not land above an archived session's rank" do
    spot(9_000, title: "archived top", status: :archived)
    spot(40)
    session = priority

    patch update_scheduling_class_session_url(session),
      params: { scheduling_class: SessionGenesis::SPOT, place: "top_of_spot" }, as: :json

    assert_equal 40 + SessionPrecedence::SLOT_GAP, session.reload.precedence
  end

  # A stale page can name a row that has since left the queue. It must not be
  # nudged: nobody is looking at it, and its rank is what a later demotion or
  # promotion reads.
  test "a neighbour that is no longer in the spot queue is ignored" do
    archived = spot(50, title: "archived neighbour", status: :archived)
    moved = spot(1)

    patch reorder_precedence_session_url(moved),
      params: { above_id: nil, below_id: archived.id }, as: :json

    assert_response :success
    assert_equal 50, archived.reload.precedence, "an archived row must not be nudged"
    assert_equal SessionPrecedence::DEFAULT, moved.reload.precedence,
      "with no usable neighbour the drop takes the default"
  end

  test "a drag that changes nothing writes no log line" do
    above = spot(100)
    below = spot(50)
    moved = spot(75)

    assert_no_difference -> { moved.logs.count } do
      patch reorder_precedence_session_url(moved),
        params: { above_id: above.id, below_id: below.id }, as: :json
    end
    assert_response :success
    assert_equal 75, moved.reload.precedence
  end

  test "a neighbour that has since disappeared still places the drop" do
    below = spot(50)
    moved = spot(1)

    patch reorder_precedence_session_url(moved),
      params: { above_id: 999_999, below_id: below.id }, as: :json

    assert_response :success
    assert_equal 50 + SessionPrecedence::SLOT_GAP, moved.reload.precedence
  end

  # --- demote / promote -------------------------------------------------------

  test "demoting a priority session lands it above the top of the spot queue" do
    spot(70)
    session = priority

    patch update_scheduling_class_session_url(session),
      params: { scheduling_class: SessionGenesis::SPOT, place: "top_of_spot" }, as: :json

    assert_response :success
    session.reload
    assert session.spot?
    assert_equal 70 + SessionPrecedence::SLOT_GAP, session.precedence
  end

  test "promoting a spot session keeps the rank it will land on if demoted again" do
    session = spot(64)

    patch update_scheduling_class_session_url(session),
      params: { scheduling_class: SessionGenesis::PRIORITY }, as: :json

    assert_response :success
    session.reload
    assert session.priority?
    assert_equal 64, session.precedence, "the rank rides along so the round trip is coherent"
  end

  # The HTML form on the session detail page shares the endpoint with the ranked
  # view's fetch, so it must keep redirecting rather than answering JSON.
  test "the scheduling class form still redirects for an HTML request" do
    session = priority

    patch update_scheduling_class_session_url(session),
      params: { scheduling_class: SessionGenesis::SPOT }

    assert_redirected_to session_path(session)
  end
end
