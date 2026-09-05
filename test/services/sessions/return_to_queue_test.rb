# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# Rest-state selection for a session Zimmer gave up on before it ever ran
# (tadasant/zimmer#602).
#
# `needs_input` is the homepage's action list. A session that was interrupted
# while its first job was starting, or that the spot gate held before it was
# ever dispatched, has nothing to ask — and nothing re-queues it there, because
# every start path reads `waiting`. These tests pin both halves: the sessions
# that must be returned to the queue, and the ones that must be left in front of
# a human.
class Sessions::ReturnToQueueTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  def unstarted_session(**attrs)
    Session.create!(
      git_root: "https://github.com/t/r.git",
      prompt: "do the work",
      genesis: SessionGenesis::GITHUB_ISSUE,
      status: :needs_input,
      **attrs
    )
  end

  test "a session that never ran is returned to waiting" do
    session = unstarted_session

    result = Sessions::ReturnToQueue.call(session, reason: "recovery could not continue it")

    assert result.returned?, "expected the service to return the session to the queue"
    assert_equal "waiting", session.reload.status
    assert_equal 1, session.metadata[Sessions::ReturnToQueue::COUNT_KEY]
    assert_equal "recovery could not continue it", session.metadata[Sessions::ReturnToQueue::REASON_KEY]
    assert session.logs.any? { |log| log.content.include?("Returning it to the queue") }
  end

  # `paused_by` is what both recovery sweeps select on AND one of
  # StalledSessionStart's dormant markers, so leaving it behind would hand the
  # session back to the sweeps that just gave up on it while hiding it from the
  # one sweep that can actually start it.
  test "the return drops the recovery marker" do
    session = unstarted_session(metadata: { "paused_by" => "recovery" })

    assert Sessions::ReturnToQueue.call(session, reason: "gave up").returned?

    assert_nil session.reload.metadata["paused_by"]
  end

  # The guard. A session with a runtime session id has a conversation behind it,
  # and its `needs_input` may be a real question.
  test "a session with a runtime session id is left in needs_input" do
    session = unstarted_session(session_id: SecureRandom.uuid)

    result = Sessions::ReturnToQueue.call(session, reason: "gave up")

    assert result.declined?, "a session that has run is not this service's case"
    assert_equal "needs_input", session.reload.status
  end

  # A blank `session_id` is not enough on its own: a runtime that mints its own
  # id (Codex) can have written a whole turn while Zimmer's column is still
  # empty, and re-queueing that session would run its prompt a second time.
  test "a session whose runtime wrote a conversation is left in needs_input" do
    session = unstarted_session
    RuntimeConversationPresence.stubs(:persisted?).returns(true)

    result = Sessions::ReturnToQueue.call(session, reason: "gave up")

    assert result.declined?
    assert_equal "needs_input", session.reload.status
  end

  # The same carve-out StalledSessionStart makes: a prompt-less session is one
  # waiting for a human to send it something, and no sweep would start it.
  test "a prompt-less session is left in needs_input" do
    session = unstarted_session
    session.update_column(:prompt, nil)

    result = Sessions::ReturnToQueue.call(session, reason: "gave up")

    assert result.declined?
    assert_equal "needs_input", session.reload.status
  end

  test "a session in a frozen category is left alone" do
    category = Category.create!(name: "Frozen #{SecureRandom.hex(4)}", is_frozen: true)
    session = unstarted_session(category: category)

    result = Sessions::ReturnToQueue.call(session, reason: "gave up")

    assert result.declined?
    assert_equal "needs_input", session.reload.status
  end

  test "a session that is not resting in needs_input is left alone" do
    session = unstarted_session
    session.update!(status: :waiting)

    assert Sessions::ReturnToQueue.call(session, reason: "gave up").declined?
    assert_equal "waiting", session.reload.status
  end

  # The bound. MAX_INTERRUPTED_START_REQUEUES exists because a start that cannot
  # survive re-queues forever; this is the same hazard one level up, so the
  # return has to run out too.
  test "the return is bounded and the session finally rests in needs_input" do
    session = unstarted_session

    Sessions::ReturnToQueue::MAX_RETURNS.times do |i|
      session.update!(status: :needs_input)
      result = Sessions::ReturnToQueue.call(session, reason: "gave up")
      assert result.returned?, "return #{i + 1} should still be within budget"
      assert_equal "waiting", session.reload.status
    end

    session.update!(status: :needs_input)
    result = Sessions::ReturnToQueue.call(session, reason: "gave up")

    assert result.exhausted?, "the budget must run out rather than looping forever"
    assert_equal "needs_input", session.reload.status
    assert_equal Sessions::ReturnToQueue::MAX_RETURNS,
      session.metadata[Sessions::ReturnToQueue::COUNT_KEY]
    assert session.metadata[Sessions::ReturnToQueue::EXHAUSTED_KEY].present?
  end

  # A repair that cannot run must not become the thing that breaks the give-up
  # path it is called from — and must leave nothing half-done behind it. Dropping
  # `paused_by` without the move is worse than doing nothing: neither recovery
  # sweep selects the session (they match the marker) and no start path reads it
  # (they match `waiting`), which is the dead end this whole service removes.
  test "a failed transition leaves the row exactly as it found it" do
    session = unstarted_session(metadata: { "paused_by" => "recovery" })
    Session.any_instance.stubs(:sleep!).raises(StandardError, "boom")

    result = Sessions::ReturnToQueue.call(session, reason: "gave up")

    assert result.declined?
    session.reload
    assert_equal "needs_input", session.status
    assert_equal "recovery", session.metadata["paused_by"],
      "the marker must survive a return that did not happen"
    assert_nil session.metadata[Sessions::ReturnToQueue::COUNT_KEY],
      "an attempt that rolled back must not spend budget"
  end

  # And the in-memory copy the caller is still holding has to agree with the row,
  # because the callers read it (announce_abandoned_pause, the sweeps' own logging).
  test "a failed transition leaves the caller holding a truthful session object" do
    session = unstarted_session(metadata: { "paused_by" => "recovery" })
    Session.any_instance.stubs(:sleep!).raises(StandardError, "boom")

    Sessions::ReturnToQueue.call(session, reason: "gave up")

    assert_equal "recovery", session.metadata["paused_by"],
      "the rolled-back write must not linger on the object the caller kept"
  end

  # === The two owners that make `waiting` a real re-dispatch, not a shrug ===

  # An ordinary never-started session lands back in the population
  # StalledSessionStart restarts — and the sweep really does start it, which is
  # the whole claim `waiting` rests on.
  test "a returned session is started by the stalled-start sweep" do
    session = unstarted_session(metadata: { "paused_by" => "recovery" })
    assert Sessions::ReturnToQueue.call(session, reason: "gave up").returned?

    session.update_columns(created_at: 1.hour.ago, updated_at: 1.hour.ago)
    assert_includes StalledSessionStart.stalled_sessions.to_a, session.reload

    assert_enqueued_with(job: AgentSessionJob) { StalledSessionStart.sweep! }

    assert_equal 1, session.reload.metadata[StalledSessionStart::RESTART_COUNT]
  end

  # And the other branch of that sweep, which is where most of the reported
  # backlog would land: a first turn older than MAX_STALL_AGE is failed rather
  # than run blind. That is still the point of the move — `failed` is a visible
  # row with a reason on it, and the `needs_input` it replaces was a slot in the
  # action queue nothing was ever going to act on.
  test "a returned session whose first turn is stale is failed by the sweep, not left invisible" do
    session = unstarted_session(metadata: { "paused_by" => "recovery" })
    assert Sessions::ReturnToQueue.call(session, reason: "gave up").returned?

    session.update_columns(created_at: 3.days.ago, updated_at: 3.days.ago)

    assert_no_enqueued_jobs(only: AgentSessionJob) { StalledSessionStart.sweep! }

    session.reload
    assert_equal "failed", session.status
    assert_includes session.metadata["failure_reason"], "Session never started"
  end

  # The disqualifier the return cannot drop, because it is not a metadata marker:
  # a session with a pending one-time wake is partitioned out of every
  # StalledSessionStart batch, so moving it would hide it from both owners.
  test "a session with a wake of its own armed is left in needs_input" do
    session = unstarted_session
    Session.any_instance.stubs(:awaiting_scheduled_wake?).returns(true)

    result = Sessions::ReturnToQueue.call(session, reason: "gave up")

    assert result.declined?
    assert_equal "needs_input", session.reload.status
  end

  # And a spot-gate-held one lands back in the population SpotHoldSweepJob
  # re-arms — the population `SpotSessionHold.held?` cannot see while the session
  # sits in `needs_input`.
  test "a returned spot-held session is picked up by the spot hold sweep" do
    session = unstarted_session(metadata: {
      "paused_by" => "recovery",
      SpotSessionHold::HELD_AT => 3.hours.ago.utc.iso8601,
      SpotSessionHold::HELD_REASON => "at_utilization_limit",
      SpotSessionHold::HELD_RETRY_AT => 2.hours.ago.utc.iso8601,
      SpotSessionHold::HELD_COUNT => 2
    })

    assert_not SpotSessionHold.held?(session),
      "a held session parked in needs_input is invisible to the sweep that re-arms it"

    assert Sessions::ReturnToQueue.call(session, reason: "gave up").returned?

    session.reload
    assert SpotSessionHold.held?(session)
    assert_includes SpotSessionHold.overdue_sessions.to_a, session
  end
end
