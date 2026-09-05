# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# Every model-side broadcast goes through BroadcastService — and lands on exactly
# the stream and target it landed on before it did.
#
# Those are two separate claims and this file makes both, because only one of
# them is cheap to see. "A broadcast happened" is what a counting test asserts,
# and a broadcast sent to the wrong stream or the wrong target still happens: the
# only symptom is a session card or a timeline that silently stops updating in
# somebody's open tab. So each call site below pins its action, stream, target
# and partial by value.
#
# The second half is the behaviour this routing exists to buy — see #524. Six of
# these methods used to have no rescue at all while sitting on `after_*_commit`,
# so a dead cable failed whoever saved the row; seven logged at ERROR, which on
# this deployment is a page for the exact transient the circuit breaker exists to
# absorb quietly.
class BroadcastDelegationTest < ActiveSupport::TestCase
  setup do
    @session = sessions(:running)
    @session.update!(status: :running, title: "Delegation test")
    # The breaker is class-level state shared by every test in this worker, and a
    # test that leaves it open paints "live updates paused" across unrelated
    # system tests (see the flake in #114). Bracket it on both sides.
    BroadcastService.new.reset_circuit_breaker
    # Retries sleep 0.1/0.2/0.4s; the failure tests below drive many of them.
    BroadcastService.any_instance.stubs(:sleep)
  end

  teardown do
    BroadcastService.new.reset_circuit_breaker
  end

  # === The arguments, pinned per call site ===

  test "broadcast_status_badge replaces the badge on the session status stream" do
    assert_broadcast_arguments(
      -> { @session.send(:broadcast_status_badge) },
      action: :replace,
      stream: "session_#{@session.id}_status",
      target: "session_#{@session.id}_status_badge",
      partial: "sessions/status_badge",
      locals: { agent_session: @session }
    )
  end

  test "broadcast_running_loader replaces the loader on the session status stream" do
    assert_broadcast_arguments(
      -> { @session.send(:broadcast_running_loader) },
      action: :replace,
      stream: "session_#{@session.id}_status",
      target: "session_#{@session.id}_running_loader",
      partial: "sessions/running_loader",
      locals: { agent_session: @session }
    )
  end

  test "broadcast_ranked_row replaces the status pill on the ranked stream" do
    assert_broadcast_arguments(
      -> { @session.send(:broadcast_ranked_row) },
      action: :replace,
      stream: Session::RANKED_STREAM,
      target: "ranked_row_status_#{@session.id}",
      partial: "sessions/ranked_row_status",
      locals: { agent_session: @session }
    )
  end

  test "broadcast_ranked_membership appends a delivery to the ranked stream" do
    assert_broadcast_arguments(
      -> { @session.send(:broadcast_ranked_membership) },
      action: :append,
      stream: Session::RANKED_STREAM,
      target: "ranked_deliveries",
      html: true
    )
  end

  test "broadcast_follow_up_form replaces the form on the session status stream" do
    assert_broadcast_arguments(
      -> { @session.send(:broadcast_follow_up_form) },
      action: :replace,
      stream: "session_#{@session.id}_status",
      target: "session_#{@session.id}_follow_up_form",
      html: true
    )
  end

  test "broadcast_header_actions replaces the header actions on the session status stream" do
    assert_broadcast_arguments(
      -> { @session.send(:broadcast_header_actions) },
      action: :replace,
      stream: "session_#{@session.id}_status",
      target: "session_#{@session.id}_header_actions",
      html: true
    )
  end

  test "broadcast_metadata_change replaces the metadata partial on the session status stream" do
    assert_broadcast_arguments(
      -> { @session.send(:broadcast_metadata_change) },
      action: :replace,
      stream: "session_#{@session.id}_status",
      target: "session_#{@session.id}_metadata",
      html: true
    )
  end

  test "broadcast_custom_metadata_change replaces header actions, and metadata only when MCP status moved" do
    without_mcp = capture_turbo_broadcasts { @session.send(:broadcast_custom_metadata_change, mcp_status_changed: false) }
    assert_equal [ [ :replace, "session_#{@session.id}_status", "session_#{@session.id}_header_actions" ] ],
                 without_mcp.map { |b| [ b.action, b.stream, b.target ] }

    with_mcp = capture_turbo_broadcasts { @session.send(:broadcast_custom_metadata_change, mcp_status_changed: true) }
    assert_equal [
      [ :replace, "session_#{@session.id}_status", "session_#{@session.id}_header_actions" ],
      [ :replace, "session_#{@session.id}_status", "session_#{@session.id}_metadata" ]
    ], with_mcp.map { |b| [ b.action, b.stream, b.target ] }
  end

  test "broadcast_update_to_sessions_index replaces this session's card on the index stream" do
    assert_broadcast_arguments(
      -> { @session.send(:broadcast_update_to_sessions_index) },
      action: :replace,
      stream: "sessions_index_individual",
      target: ActionView::RecordIdentifier.dom_id(@session),
      html: true
    )
  end

  test "broadcast_create_to_sessions_index prepends the card into the uncategorized grid" do
    assert_broadcast_arguments(
      -> { @session.send(:broadcast_create_to_sessions_index) },
      action: :prepend,
      stream: "sessions_index_individual",
      target: "sessions_grid",
      html: true
    )
  end

  test "broadcast_remove_from_sessions_index removes the card from the index stream" do
    assert_broadcast_arguments(
      -> { @session.send(:broadcast_remove_from_sessions_index) },
      action: :remove,
      stream: "sessions_index_individual",
      target: ActionView::RecordIdentifier.dom_id(@session)
    )
  end

  test "an archived session is removed from the index rather than replaced on it" do
    @session.update!(status: :archived)
    captured = capture_turbo_broadcasts { @session.send(:broadcast_update_to_sessions_index) }

    assert_equal [ [ :remove, "sessions_index_individual", ActionView::RecordIdentifier.dom_id(@session) ] ],
                 captured.map { |b| [ b.action, b.stream, b.target ] }
  end

  test "broadcast_provenance_change_to_hierarchy replaces the panel for every session in the lineage" do
    parent = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Parent", status: :running)
    child = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Child",
                            parent_session_id: parent.id, status: :running)

    captured = capture_turbo_broadcasts { child.broadcast_provenance_change_to_hierarchy }

    expected = SessionHierarchy.new(child).session_ids.map do |viewer_id|
      [ :replace, "session_#{viewer_id}_status", "session_#{viewer_id}_provenance" ]
    end
    assert_equal expected.sort, captured.map { |b| [ b.action, b.stream, b.target ] }.sort
    assert captured.all? { |b| b.html.present? }, "provenance panels are broadcast as pre-rendered HTML"
  end

  test "Log#broadcast_append_to_timeline appends the item partial to the session timeline" do
    log = Log.create!(session: @session, level: "info", content: "hello")

    captured = capture_turbo_broadcasts { log.send(:broadcast_append_to_timeline) }

    assert_equal 1, captured.length
    broadcast = captured.first
    assert_equal :append, broadcast.action
    assert_equal "session_#{@session.id}_timeline", broadcast.stream
    assert_equal "session_#{@session.id}_timeline", broadcast.target
    assert_equal "timeline_items/item", broadcast.partial
    assert_equal({ type: "log", level: "info", content: "hello" },
                 broadcast.locals[:item].slice(:type, :level, :content))
  end

  test "SessionStatusSummary#broadcast_panel_replacement replaces the status panel" do
    summary = SessionStatusSummary.create!(session: @session, state: "ready", summary: "s",
                                           transcript_line_count: 1, generated_at: Time.current)

    assert_broadcast_arguments(
      -> { summary.send(:broadcast_panel_replacement) },
      action: :replace,
      stream: "session_#{@session.id}_status",
      target: "session_#{@session.id}_status_panel",
      partial: "sessions/status_panel",
      locals: { agent_session: @session }
    )
  end

  test "broadcast_status_change fans out to the seven detail-page and ranked targets" do
    captured = capture_turbo_broadcasts { @session.send(:broadcast_status_change) }

    status = "session_#{@session.id}_status"
    assert_equal [
      [ :replace, status, "session_#{@session.id}_status_badge" ],
      [ :append,  Session::RANKED_STREAM, "ranked_deliveries" ],
      [ :replace, Session::RANKED_STREAM, "ranked_row_status_#{@session.id}" ],
      [ :replace, status, "session_#{@session.id}_follow_up_form" ],
      [ :replace, status, "session_#{@session.id}_running_loader" ],
      [ :replace, status, "session_#{@session.id}_header_actions" ],
      [ :replace, status, "session_#{@session.id}_metadata" ]
    ], captured.map { |b| [ b.action, b.stream, b.target ] }
  end

  # === Failure isolation (the point of #524) ===

  test "a dead cable does not fail the commit callback that created a session" do
    created = nil
    capture_turbo_broadcasts(raises: StandardError.new("cable down")) do
      assert_nothing_raised do
        created = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Created during an outage")
      end
    end

    assert created.persisted?, "the row must still be committed when its broadcast fails"
  end

  test "a dead cable does not fail the commit callback that updated a session" do
    capture_turbo_broadcasts(raises: StandardError.new("cable down")) do
      assert_nothing_raised { @session.update!(status: :needs_input) }
    end

    assert_equal "needs_input", @session.reload.status
  end

  test "a dead cable does not fail the commit callback that created a log line" do
    log = nil
    capture_turbo_broadcasts(raises: StandardError.new("cable down")) do
      assert_nothing_raised { log = Log.create!(session: @session, level: "info", content: "during an outage") }
    end

    assert log.persisted?
  end

  test "a dead cable does not fail an atomic metadata merge" do
    capture_turbo_broadcasts(raises: StandardError.new("cable down")) do
      assert_nothing_raised { @session.merge_metadata!("clone_path" => "/tmp/outage") }
    end

    assert_equal "/tmp/outage", @session.reload.metadata["clone_path"]
  end

  test "a failed model-side broadcast feeds the breaker and logs no ERROR" do
    entries = capture_log_entries do
      capture_turbo_broadcasts(raises: StandardError.new("cable down")) do
        @session.send(:broadcast_status_badge)
      end
    end

    assert_operator BroadcastService.circuit_breaker_failures, :>, 0,
                    "the failure must be recorded against the circuit breaker"
    broadcast_errors = entries.select { |severity, message| severity == "ERROR" && message.include?("Broadcast failed") }
    assert_empty broadcast_errors,
                 "a dropped broadcast must not page: it is logged at WARN and reported to ErrorReporter"
    assert entries.any? { |severity, message| severity == "WARN" && message.include?("Broadcast failed after retries") },
           "the failure is still logged, at WARN"
  end

  test "a failed model-side broadcast is still reported to ErrorReporter" do
    reported = []
    ErrorReporter.stubs(:report_exception).with { |error, **| reported << error; true }

    capture_turbo_broadcasts(raises: StandardError.new("cable down")) do
      @session.send(:broadcast_status_badge)
    end

    assert_equal [ "cable down" ], reported.map(&:message)
  end

  test "an open circuit breaker suppresses model-side broadcasts too" do
    BroadcastService.circuit_breaker_failures = BroadcastService::CIRCUIT_BREAKER_THRESHOLD
    BroadcastService.circuit_breaker_opened_at = Time.current

    captured = capture_turbo_broadcasts { @session.send(:broadcast_status_badge) }

    assert_empty captured,
                 "the 'live updates paused' banner claims these broadcasts are paused — they must actually be"
  end

  test "a render failure is isolated exactly like a cable failure" do
    SessionsController.stubs(:render).raises(StandardError, "partial blew up")

    assert_nothing_raised { @session.send(:broadcast_header_actions) }
    assert_operator BroadcastService.circuit_breaker_failures, :>, 0
  end

  private

  def assert_broadcast_arguments(callable, action:, stream:, target:, partial: nil, locals: nil, html: false)
    captured = capture_turbo_broadcasts { callable.call }

    assert_equal 1, captured.length, "expected exactly one broadcast, got #{captured.inspect}"
    broadcast = captured.first
    assert_equal action, broadcast.action
    assert_equal stream, broadcast.stream
    assert_equal target, broadcast.target
    if partial
      assert_equal partial, broadcast.partial
    else
      assert_nil broadcast.partial
    end
    assert_equal locals, broadcast.locals if locals
    if html
      assert broadcast.html.present?, "expected pre-rendered HTML"
    else
      assert_nil broadcast.html
    end
  end
end
