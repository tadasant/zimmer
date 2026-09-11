# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# Detaching an uncle edge recorded in error (#299).
#
# The rules that matter here are all about DIRECTION and about not succeeding
# quietly: an uncle edge means "A is senior to B" and nothing else, so a remover
# that is loose about which way round the pair was named would delete the opposite
# claim from the one the caller meant — and `Sessions::RecordUncleEdge` inverts
# edges, so both directions genuinely occur in the same table for the same pair.
class Sessions::RemoveUncleEdgeTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  def create_session(parent: nil, title: nil)
    Session.create!(
      agent_runtime: "claude_code",
      prompt: "work",
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      title: title,
      parent_session_id: parent&.id
    )
  end

  def record(junior, acting_session_id, source: "test:recorded")
    Sessions::RecordUncleEdge.call(junior: junior, acting_session_id: acting_session_id, source: source)
  end

  def remove(junior, uncle_session_id, actor: "a test", source: "test:removed")
    Sessions::RemoveUncleEdge.call(
      junior: junior,
      uncle_session_id: uncle_session_id,
      actor: actor,
      source: source
    )
  end

  def edge?(junior, uncle)
    SessionUncleLink.exists?(session_id: junior.id, uncle_session_id: uncle.id)
  end

  # --- The happy path --------------------------------------------------------

  test "removes the edge the caller named" do
    uncle = create_session
    junior = create_session
    record(junior, uncle.id)
    assert edge?(junior, uncle)

    outcome = remove(junior, uncle.id)

    assert_not edge?(junior, uncle)
    assert_equal junior.id, outcome.junior_id
    assert_equal uncle.id, outcome.uncle_id
  end

  # The outcome carries the edge's provenance because the row is gone by the time
  # any caller could read it, and every surface reports it back.
  test "the outcome carries the removed edge's source and creation time" do
    uncle = create_session
    junior = create_session
    record(junior, uncle.id, source: "mcp:action_session.follow_up")
    link = SessionUncleLink.find_by!(session_id: junior.id, uncle_session_id: uncle.id)

    outcome = remove(junior, uncle.id)

    assert_equal "mcp:action_session.follow_up", outcome.edge_source
    assert_in_delta link.created_at, outcome.recorded_at, 1.second
  end

  test "accepts the uncle as a slug, the same identifiers as every other session parameter" do
    uncle = create_session
    junior = create_session
    uncle.update!(slug: "the-senior-20260911-1102")
    record(junior, uncle.id)

    remove(junior, uncle.slug)

    assert_not edge?(junior, uncle)
  end

  # --- Only the named edge ---------------------------------------------------

  test "leaves this session's other seniors alone" do
    first = create_session
    second = create_session
    junior = create_session
    record(junior, first.id)
    record(junior, second.id)

    remove(junior, first.id)

    assert_not edge?(junior, first)
    assert edge?(junior, second)
  end

  test "leaves the senior's own juniors alone" do
    uncle = create_session
    junior = create_session
    other_junior = create_session
    record(junior, uncle.id)
    record(other_junior, uncle.id)

    remove(junior, uncle.id)

    assert_not edge?(junior, uncle)
    assert edge?(other_junior, uncle)
  end

  # The spawn edge is history. Removal narrows the lineage graph; it does not
  # rewrite what happened.
  test "does not touch parent_session_id" do
    parent = create_session
    junior = create_session(parent: parent)
    uncle = create_session
    record(junior, uncle.id)

    remove(junior, uncle.id)

    assert_equal parent.id, junior.reload.parent_session_id
  end

  # --- Direction ------------------------------------------------------------

  # The case the class comment is about: RecordUncleEdge INVERTS an edge when the
  # junior turns round and queues its senior, so after an inversion the row for
  # this pair points the other way. Removing "whichever edge joins these two"
  # would delete a claim the caller did not name.
  test "refuses the inverted direction and names the one that exists" do
    a = create_session
    b = create_session
    record(b, a.id)
    # b was junior; now b queues a, which inverts the edge to b -> a.
    assert record(a, b.id).inverted?
    assert edge?(a, b)

    error = assert_raises(Sessions::RemoveUncleEdge::NotFound) { remove(b, a.id) }

    assert_includes error.message, "points the other way"
    assert_includes error.message, "##{b.id} is senior to ##{a.id}"
    assert edge?(a, b), "the edge that does exist must survive a request that named the other direction"
  end

  test "a pair joined in neither direction is a plain not-found" do
    uncle = create_session
    junior = create_session

    error = assert_raises(Sessions::RemoveUncleEdge::NotFound) { remove(junior, uncle.id) }

    assert_includes error.message, "No uncle edge ##{uncle.id} → ##{junior.id}"
    assert_not_includes error.message, "points the other way"
  end

  # --- Bad input ------------------------------------------------------------

  test "a blank uncle_session_id is an error, not a no-op" do
    junior = create_session

    assert_raises(Sessions::RemoveUncleEdge::Error) { remove(junior, nil) }
    assert_raises(Sessions::RemoveUncleEdge::Error) { remove(junior, "  ") }
  end

  test "an unresolvable uncle_session_id is not-found and names what was asked for" do
    junior = create_session

    error = assert_raises(Sessions::RemoveUncleEdge::NotFound) { remove(junior, 99_999_999) }

    assert_includes error.message, "99999999"
  end

  # Non-numeric junk must not be coerced to an id — the same guard the write path
  # depends on, for the same reason: acting on an arbitrary other session is worse
  # than refusing.
  test "a malformed uncle_session_id removes nothing" do
    uncle = create_session
    junior = create_session
    record(junior, uncle.id)

    assert_raises(Sessions::RemoveUncleEdge::NotFound) { remove(junior, "not-a-session") }

    assert edge?(junior, uncle)
  end

  # --- The audit trail ------------------------------------------------------

  # The write path logs into both ends. So does this, for the same reason: the
  # edge changed whose human messages BOTH sessions' prompts carry, so each end
  # owes its own reader the record.
  test "the removal is logged into both sessions' timelines" do
    uncle = create_session
    junior = create_session
    record(junior, uncle.id, source: "mcp:action_session.follow_up")
    junior.logs.delete_all
    uncle.logs.delete_all

    remove(junior, uncle.id, actor: "session ##{uncle.id} via the MCP API", source: "mcp:action_session.remove_uncle")

    [ junior, uncle ].each do |session|
      log = session.logs.reload.last
      assert_not_nil log, "session ##{session.id} has no record of the removal"
      assert_includes log.content, "Uncle edge removed"
      # Both ids, so a reader of either log can tell which end they are on.
      assert_includes log.content, "##{uncle.id}"
      assert_includes log.content, "##{junior.id}"
      # What wrote the edge, and who removed it.
      assert_includes log.content, "mcp:action_session.follow_up"
      assert_includes log.content, "session ##{uncle.id} via the MCP API"
      assert_includes log.content, "mcp:action_session.remove_uncle"
    end
  end

  test "a failure to log does not undo a removal that already happened" do
    uncle = create_session
    junior = create_session
    record(junior, uncle.id)
    Log.any_instance.stubs(:save!).raises(ActiveRecord::StatementInvalid, "boom")

    remove(junior, uncle.id)

    assert_not edge?(junior, uncle)
  end

  # --- The panel repaint ----------------------------------------------------

  # The hierarchy panel repaints from SessionUncleLink's `after_destroy_commit`,
  # which only fires for a destroyed record. A `delete_all`-style removal would
  # leave every open browser showing the edge until the next full page load — so
  # this pins that the service destroys the row rather than deleting it.
  test "both ends are queued for a provenance repaint" do
    uncle = create_session
    junior = create_session
    record(junior, uncle.id)

    assert_enqueued_jobs 2, only: SessionProvenanceBroadcastJob do
      remove(junior, uncle.id)
    end
  end

  # The panel each end repaints is its own post-removal hierarchy, which is the
  # whole point: after the edge is gone the two sessions may be in separate
  # graphs, and each has to be told about the one it is now in.
  test "the repaint renders the hierarchy without the removed edge" do
    uncle = create_session
    junior = create_session
    record(junior, uncle.id)
    broadcasts = []
    Turbo::StreamsChannel.stubs(:broadcast_replace_to).with do |stream, **options|
      broadcasts << [ stream, options ]
      true
    end

    perform_enqueued_jobs(only: SessionProvenanceBroadcastJob) { remove(junior, uncle.id) }

    junior_html = broadcasts.find { |stream, _| stream == "session_#{junior.id}_status" }&.last&.dig(:html)
    assert_not_nil junior_html, "the junior's provenance panel was never repainted"
    assert_not_includes junior_html, "also senior:"
  end
end
