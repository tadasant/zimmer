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

  # `acting_session_id` reads the same identifiers as every other session
  # parameter, because both go through `Session.locate`.
  test "a declared slug is accepted, and a digit-leading one names its own session" do
    actor = create_session
    decoy = create_session
    target = create_session
    actor.update!(slug: "#{decoy.id}-the-actor-20260830-1102")

    assert_equal :created, record(target, actor.slug).action
    assert edge?(target, actor)
    refute edge?(target, decoy), "the leading digits of a slug are not an id"
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

  # Regression: inversion used to delete only the ONE direct edge, so when the
  # actor was also reachable from the target by a longer uncle path, writing the
  # reverse closed a cycle through the middle session.
  test "inversion is refused when the actor stays senior by another path" do
    a = create_session
    b = create_session
    x = create_session

    record(a, b.id)   # b → a
    record(a, x.id)   # x → a
    record(x, b.id)   # b → x

    # b is senior to a directly AND via x. Inverting only the direct edge would
    # leave a → b → x → a.
    outcome = record(b, a.id)

    assert_equal :would_create_cycle, outcome.action
    assert edge?(a, b), "the direct edge is restored, not left deleted"
    assert edge?(x, b)
    assert edge?(a, x)
    assert_cycle_free([ a, b, x ])
  end

  # Regression: the reachability search was depth-bounded at 8, so a cycle
  # spanning more hops than that was invisible to the check and got created.
  test "a cycle longer than the render depth bound is still refused" do
    chain = Array.new(SessionHierarchy::MAX_DEPTH + 4) { create_session }
    # top → … → bottom, each link an uncle edge.
    chain.each_cons(2) { |senior, junior| record(junior, senior.id) }

    # The bottom of the chain tries to become senior to the top, which would
    # close the whole loop.
    outcome = record(chain.first, chain.last.id)

    assert_equal :would_create_cycle, outcome.action
    assert_cycle_free(chain)
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

  # Both ends, because the abuse worth catching is a session calling follow_up on
  # ITSELF while naming an unrelated session as the actor: that grafts the
  # unrelated hierarchy into its own scope without ever touching it. Logging only
  # the junior would leave the hierarchy that was reached into with no trace.
  test "recording an edge writes a log into both sessions" do
    actor = create_session
    target = create_session

    record(target, actor.id, source: "mcp:action_session.follow_up")

    [ target, actor ].each do |session|
      log = session.logs.order(:id).last
      assert_includes log.content, "Uncle edge recorded", "expected a log on ##{session.id}"
      assert_includes log.content, "##{actor.id}"
      assert_includes log.content, "##{target.id}"
      assert_includes log.content, "mcp:action_session.follow_up"
    end
  end

  test "the edge log names both ends rather than saying \"this session\"" do
    actor = create_session
    target = create_session

    record(target, actor.id)

    # The same line lands in two logs, so a reader has to be able to tell which
    # end they are looking at without inferring it from which log they opened.
    refute_includes target.logs.order(:id).last.content, "this session"
  end

  # The log is the only place an operator sees which way an edge went, and the
  # two arrows are trivially easy to write backwards — pin the direction, not
  # just the phrase.
  test "the inversion log names the old edge and the new one the right way round" do
    senior = create_session
    junior = create_session

    record(junior, senior.id)
    record(senior, junior.id)

    content = senior.logs.order(:id).last.content
    assert_includes content, "##{senior.id} was senior to ##{junior.id}"
    assert_includes content, "the uncle edge ##{senior.id} → ##{junior.id} was replaced by ##{junior.id} → ##{senior.id}"
    # And the graph agrees with what the log claims.
    assert edge?(senior, junior)
    refute edge?(junior, senior)
  end

  test "an inversion says so in both logs" do
    senior = create_session
    junior = create_session

    record(junior, senior.id)
    record(senior, junior.id)

    assert_includes senior.logs.order(:id).last.content, "Seniority inverted"
    assert_includes junior.logs.order(:id).last.content, "Seniority inverted"
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
