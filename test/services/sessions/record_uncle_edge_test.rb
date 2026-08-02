# frozen_string_literal: true

require "test_helper"

# The rules that decide whether a queue/interrupt becomes a lineage edge.
#
# These are the tests that hold the graph together: the acyclicity invariant
# lives here rather than in SessionHierarchy, which only has bounds as a
# backstop.
class Sessions::RecordUncleEdgeTest < ActiveSupport::TestCase
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

  def record(junior, acting_session_id, source: "test")
    Sessions::RecordUncleEdge.call(junior: junior, acting_session_id: acting_session_id, source: source)
  end

  def edge?(junior, uncle)
    SessionUncleLink.exists?(session_id: junior.id, uncle_session_id: uncle.id)
  end

  # --- Who is the actor ------------------------------------------------------

  test "an unrelated session that queues another becomes its uncle" do
    actor = create_session
    target = create_session

    outcome = record(target, actor.id)

    assert_equal :created, outcome.action
    assert outcome.recorded?
    assert edge?(target, actor)
  end

  test "a declared id given as a string is accepted" do
    actor = create_session
    target = create_session

    assert_equal :created, record(target, actor.id.to_s).action
    assert edge?(target, actor)
  end

  # The load-bearing limitation: nothing about the request identifies the
  # caller, so an absent declaration must record nothing rather than guess.
  test "no declared actor records nothing" do
    target = create_session

    [ nil, "", "   " ].each do |declared|
      outcome = record(target, declared)
      assert_equal :no_actor_declared, outcome.action
      refute outcome.recorded?
    end

    assert_equal 0, SessionUncleLink.count
  end

  test "an unparseable or unknown declared actor records nothing rather than raising" do
    target = create_session

    assert_equal :no_actor_declared, record(target, "not-an-id").action
    assert_equal :no_actor_declared, record(target, 999_999_999).action
    assert_equal 0, SessionUncleLink.count
  end

  test "a session messaging itself records nothing" do
    session = create_session

    assert_equal :self, record(session, session.id).action
    assert_equal 0, SessionUncleLink.count
  end

  # --- Already senior --------------------------------------------------------

  test "a spawn parent following up its own child records nothing" do
    router = create_session
    worker = create_session(parent: router)

    assert_equal :already_senior, record(worker, router.id).action
    assert_equal 0, SessionUncleLink.count
  end

  test "a spawn grandparent following up a grandchild records nothing" do
    root = create_session
    middle = create_session(parent: root)
    leaf = create_session(parent: middle)

    assert_equal :already_senior, record(leaf, root.id).action
    assert_equal 0, SessionUncleLink.count
  end

  test "a repeated interrupt from the same senior stays one edge" do
    actor = create_session
    target = create_session

    assert_equal :created, record(target, actor.id).action
    assert_equal :already_senior, record(target, actor.id).action

    assert_equal 1, SessionUncleLink.where(session_id: target.id).count
  end

  test "two different seniors both get edges" do
    first = create_session
    second = create_session
    target = create_session

    record(target, first.id)
    record(target, second.id)

    assert_equal [ first.id, second.id ].sort,
                 SessionUncleLink.where(session_id: target.id).pluck(:uncle_session_id).sort
  end

  # --- Inversion -------------------------------------------------------------

  test "a junior that calls back into its uncle inverts the edge" do
    senior = create_session
    junior = create_session

    record(junior, senior.id)
    assert edge?(junior, senior)

    outcome = record(senior, junior.id)

    assert_equal :inverted, outcome.action
    assert outcome.inverted?
    assert edge?(senior, junior), "the new direction should exist"
    refute edge?(junior, senior), "the old direction should be gone, not kept alongside"
    assert_equal 1, SessionUncleLink.count
  end

  test "inversion leaves no two-cycle behind" do
    a = create_session
    b = create_session

    record(b, a.id)
    record(a, b.id)
    record(b, a.id)

    pairs = SessionUncleLink.pluck(:session_id, :uncle_session_id)
    assert_equal 1, pairs.size, "only one direction may exist at a time"
  end

  # Spawn history is a fact about the past. Inverting it would make the tree lie
  # about something that actually happened, and nothing is gained: the two
  # sessions already share a hierarchy.
  test "a child calling back into its spawn parent records nothing and leaves the spawn edge alone" do
    router = create_session
    worker = create_session(parent: router)

    outcome = record(router, worker.id)

    assert_equal :would_create_cycle, outcome.action
    assert_equal 0, SessionUncleLink.count
    assert_equal router.id, worker.reload.parent_session_id
    assert_equal router.id, worker.lineage_parent_id
  end

  test "a descendant calling back into a distant spawn ancestor records nothing" do
    root = create_session
    middle = create_session(parent: root)
    leaf = create_session(parent: middle)

    assert_equal :would_create_cycle, record(root, leaf.id).action
    assert_equal 0, SessionUncleLink.count
  end

  # Only the DIRECT uncle edge inverts. Unwinding a longer chain would mean
  # deleting an edge neither session is party to, so the edge is refused instead.
  test "a multi-hop seniority chain is refused rather than inverted" do
    top = create_session
    middle = create_session
    bottom = create_session

    record(middle, top.id)
    record(bottom, middle.id)

    outcome = record(top, bottom.id)

    assert_equal :would_create_cycle, outcome.action
    assert edge?(middle, top), "the existing chain is untouched"
    assert edge?(bottom, middle)
    assert_equal 2, SessionUncleLink.count
  end

  # The invariant, stated directly: whatever sequence of calls arrives, the
  # combined graph never contains a cycle.
  test "no sequence of calls can construct a cycle" do
    sessions = Array.new(5) { create_session }

    sessions.each do |a|
      sessions.each do |b|
        record(b, a.id)
      end
    end

    assert_nothing_raised { assert_cycle_free(sessions) }
  end

  test "a mixed spawn and uncle graph stays cycle free" do
    root = create_session
    child = create_session(parent: root)
    outsider = create_session

    record(child, outsider.id)
    record(outsider, child.id)
    record(root, child.id)
    record(child, root.id)

    assert_cycle_free([ root, child, outsider ])
  end

  # --- Observability ---------------------------------------------------------

  test "recording an edge writes a log the reader can see" do
    actor = create_session
    target = create_session

    record(target, actor.id, source: "mcp:action_session.follow_up")

    log = target.logs.order(:id).last
    assert_includes log.content, "Uncle edge recorded"
    assert_includes log.content, "##{actor.id}"
    assert_includes log.content, "mcp:action_session.follow_up"
  end

  test "an inversion says so in the log" do
    senior = create_session
    junior = create_session

    record(junior, senior.id)
    record(senior, junior.id)

    assert_includes senior.logs.order(:id).last.content, "Seniority inverted"
  end

  private

  # Depth-first over both edge kinds from every session; a node reached twice on
  # one path is a cycle.
  def assert_cycle_free(sessions)
    sessions.each do |start|
      stack = [ [ start.id, [ start.id ] ] ]
      until stack.empty?
        current, path = stack.pop
        SessionHierarchy.child_ids_of([ current ]).each do |child_id|
          refute_includes path, child_id, "cycle reached #{child_id} via #{path.inspect}"
          stack.push([ child_id, path + [ child_id ] ])
        end
      end
    end
  end
end
