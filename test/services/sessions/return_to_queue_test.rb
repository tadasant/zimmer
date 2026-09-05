# frozen_string_literal: true

require "test_helper"

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
  # path it is called from.
  test "an unexpected failure declines rather than raising into the caller" do
    session = unstarted_session
    Session.any_instance.stubs(:sleep!).raises(StandardError, "boom")

    result = Sessions::ReturnToQueue.call(session, reason: "gave up")

    assert result.declined?
    assert_equal "needs_input", session.reload.status
  end

  # === The two owners that make `waiting` a real re-dispatch, not a shrug ===

  # An ordinary never-started session lands back in the population
  # StalledSessionStart restarts.
  test "a returned session is picked up by the stalled-start sweep" do
    session = unstarted_session(metadata: { "paused_by" => "recovery" })
    assert Sessions::ReturnToQueue.call(session, reason: "gave up").returned?

    session.update_columns(created_at: 1.hour.ago, updated_at: 1.hour.ago)

    assert_includes StalledSessionStart.stalled_sessions.to_a, session.reload,
      "a session returned to the queue must be visible to the sweep that restarts it"
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
