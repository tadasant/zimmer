# frozen_string_literal: true

require "test_helper"

# Parking a session in the spot queue. The property that separates this from its sibling
# Sessions::ScheduleWakeUp is what it does NOT do: no trigger, no wall-clock time,
# nothing that fires. What it leaves behind instead is the record SpotSessionPause
# already resumes on.
class Sessions::PauseIntoSpotQueueTest < ActiveSupport::TestCase
  def session_in(status, **attrs)
    Session.create!({
      git_root: "https://github.com/t/r.git",
      prompt: "work",
      status: status,
      session_id: "cli-#{SecureRandom.hex(4)}",
      genesis: SessionGenesis::WEB_UI
    }.merge(attrs))
  end

  test "parks the session in waiting with no trigger at all" do
    session = session_in(:needs_input)

    assert_no_difference "Trigger.count" do
      Sessions::PauseIntoSpotQueue.call(session: session)
    end

    session.reload
    assert session.waiting?
    assert_equal SpotSessionPause::QUEUED_REASON, session.metadata[SpotSessionPause::PAUSED_REASON]
    assert SpotSessionPause.paused?(session)
    assert SpotSessionPause.queued_by_user?(session)
    assert_not session.awaiting_scheduled_wake?, "the whole point: nothing is armed to wake it"
  end

  test "pins a priority session to spot so the queue can actually hold it" do
    session = session_in(:needs_input, scheduling_class: SessionGenesis::PRIORITY)

    result = Sessions::PauseIntoSpotQueue.call(session: session)

    assert result.pinned_to_spot
    assert session.reload.spot?
    assert_equal SessionGenesis::SPOT, session.scheduling_class
  end

  # A session whose genesis already classifies spot is left deriving it, so a
  # later settings change still reaches it. Pinning would freeze it for nothing.
  test "leaves a derived spot session deriving its class" do
    session = session_in(:needs_input, genesis: SessionGenesis::GITHUB_ISSUE)
    assert session.spot?, "the fixture genesis has to classify spot for this test to mean anything"

    result = Sessions::PauseIntoSpotQueue.call(session: session)

    assert_not result.pinned_to_spot
    assert_nil session.reload.scheduling_class
    assert session.spot?
  end

  test "leaves the session's queue position where its rank already put it" do
    session = session_in(:needs_input, precedence: 4_200)

    Sessions::PauseIntoSpotQueue.call(session: session)

    assert_equal 4_200, session.reload.precedence
  end

  # A wake-up hangs its resume prompt on the trigger it arms; this park has no
  # trigger, so the prompt rides on the session until the sweep picks it up.
  test "keeps a resume prompt for the sweep to deliver" do
    session = session_in(:needs_input)

    Sessions::PauseIntoSpotQueue.call(session: session, prompt: "  Re-check the deploy  ")

    assert_equal "Re-check the deploy", session.reload.metadata[SpotSessionPause::QUEUED_PROMPT]
  end

  test "stores no prompt when the box was left empty" do
    session = session_in(:needs_input)

    Sessions::PauseIntoSpotQueue.call(session: session, prompt: "   ")

    assert_not session.reload.metadata.key?(SpotSessionPause::QUEUED_PROMPT)
  end

  # A running session does not sleep mid-turn — the same deferral a scheduled
  # wake gets, for the same reason: the turn in flight is worth finishing.
  test "a running session is marked pending_sleep rather than stopped" do
    session = session_in(:running)

    result = Sessions::PauseIntoSpotQueue.call(session: session)

    assert result.pending_sleep
    session.reload
    assert session.running?
    assert_equal true, session.metadata["pending_sleep"]
    assert_equal SpotSessionPause::QUEUED_REASON, session.metadata[SpotSessionPause::PAUSED_REASON]
  end

  # Parking in the queue after arming a wake means "not then, this instead". The
  # earlier wake would otherwise still fire and pull the session straight back
  # out of the queue.
  test "supersedes a wake-up armed earlier" do
    session = session_in(:needs_input)
    Sessions::ScheduleWakeUp.call(session: session, wake_at: 2.hours.from_now.utc.strftime("%Y-%m-%dT%H:%M:%S"),
                                  prompt: "wake up", timezone: "UTC")
    assert session.reload.awaiting_scheduled_wake?

    assert_difference "Trigger.count", -1 do
      Sessions::PauseIntoSpotQueue.call(session: session)
    end

    assert_not session.reload.awaiting_scheduled_wake?
  end

  # The marker means "sleep only if something is still armed to wake you", and
  # this park destroys every armed wake and creates none — so a session carrying
  # it from a system-recovery resume would drop the sleep at turn end and come to
  # rest in needs_input holding a queue record no sweep could act on.
  test "a parked running session still sleeps at turn end when a recovery had made its sleep conditional" do
    session = session_in(:running, metadata: { SessionStateMachine::PENDING_SLEEP_REQUIRES_WAKE => true })

    Sessions::PauseIntoSpotQueue.call(session: session)

    session.reload
    assert session.running?, "the turn is still in flight"
    assert_nil session.metadata[SessionStateMachine::PENDING_SLEEP_REQUIRES_WAKE]

    session.pause!  # the turn ends

    session.reload
    assert session.waiting?, "the park has to survive the end of the turn it was made during"
    assert SpotSessionPause.paused?(session), "and the queue record has to be what the sweep finds"
  end

  test "a second park with an empty box does not resume on the first park's prompt" do
    session = session_in(:needs_input)
    Sessions::PauseIntoSpotQueue.call(session: session, prompt: "Re-check the deploy")
    session.update!(status: :needs_input)

    Sessions::PauseIntoSpotQueue.call(session: session)

    assert_not session.reload.metadata.key?(SpotSessionPause::QUEUED_PROMPT)
  end

  # The one status the service must judge differently from Sessions::ScheduleWakeUp's
  # WAKEABLE_STATUSES — Session#sleepable? is the predicate, and it lives on the
  # model so every path that parks a session asks the same question.
  test "refuses a waiting session that has never started" do
    queued = session_in(:waiting, session_id: nil)

    assert_raises(Sessions::PauseIntoSpotQueue::Error) do
      Sessions::PauseIntoSpotQueue.call(session: queued)
    end

    assert_nil (queued.reload.metadata || {})[SpotSessionPause::PAUSED_REASON]
  end

  # A dormant session is not stalled, so the "continue" nudge a refresh sends to
  # a stranded one must not reach it — that would pull it straight back out of
  # the queue it was just put in.
  test "a parked session is not nudged awake by a refresh" do
    session = session_in(:needs_input)

    Sessions::PauseIntoSpotQueue.call(session: session)

    session.reload
    assert session.waiting?
    assert_not session.continue_nudge_on_refresh?
  end

  # The record has to go when a human takes the session back by hand, or the next
  # ordinary wake-up would land in `waiting` still looking parked and the sweep
  # would resume it long before that time.
  test "the queue record is cleared by every path that restarts a session" do
    SpotSessionPause::METADATA_KEYS.each do |key|
      assert_includes Session::STALE_RETRY_METADATA_KEYS, key
    end
  end

  test "refuses a session that cannot be slept" do
    session = session_in(:failed)

    error = assert_raises(Sessions::PauseIntoSpotQueue::Error) do
      Sessions::PauseIntoSpotQueue.call(session: session)
    end

    assert_match(/cannot be put in the spot queue/, error.message)
    assert session.reload.failed?
  end
end
