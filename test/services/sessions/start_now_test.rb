# frozen_string_literal: true

require "test_helper"

# "Start it now": the operation behind the Ranked view's Start entry, and behind
# a promote to priority. The property that matters most is the one about NOT
# enqueuing — a held session already has its turn queued, and a second job for
# the same session is a second turn nobody asked for.
class Sessions::StartNowTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  def waiting_session(session_id: nil, metadata: {})
    Session.create!(
      git_root: "https://github.com/t/r.git", prompt: "work",
      status: :waiting, scheduling_class: SessionGenesis::SPOT,
      session_id: session_id, metadata: metadata
    )
  end

  def held_session(retry_at: 40.minutes.from_now, **kwargs)
    waiting_session(**kwargs, metadata: {
      SpotSessionHold::HELD_AT => 1.minute.ago.iso8601,
      SpotSessionHold::HELD_REASON => "at_utilization_limit",
      SpotSessionHold::HELD_DETAIL => "Holding spot sessions: the weekly window is ahead of its curve.",
      SpotSessionHold::HELD_RETRY_AT => retry_at.iso8601,
      SpotSessionHold::HELD_COUNT => 3
    })
  end

  # The deferred job SpotSessionHold leaves behind, as GoodJob stores it. The
  # service finds it by the session id in `arguments[0]`, the same read
  # SessionRecoveryService uses.
  def queued_turn(session, scheduled_at:, arguments: nil)
    GoodJob::Job.create!(
      active_job_id: SecureRandom.uuid,
      job_class: "AgentSessionJob",
      queue_name: "agents",
      scheduled_at: scheduled_at,
      serialized_params: {
        "job_class" => "AgentSessionJob",
        "arguments" => arguments || [ session.id ]
      }
    )
  end

  # --- a held session: pull its queued turn forward ---------------------------

  test "a held session's deferred turn is pulled forward instead of being duplicated" do
    session = held_session
    job = queued_turn(session, scheduled_at: 40.minutes.from_now)

    result = assert_no_enqueued_jobs(only: AgentSessionJob) do
      Sessions::StartNow.call(session)
    end

    assert result.started?, result.message
    assert_operator job.reload.scheduled_at, :<=, Time.current,
      "the queued turn should now be due"
    assert_equal 1, GoodJob::Job.where(job_class: "AgentSessionJob").count,
      "one session, one turn — a second job would run the prompt twice"
  end

  test "starting a held session drops the hold record it was waiting on" do
    session = held_session
    queued_turn(session, scheduled_at: 40.minutes.from_now)

    Sessions::StartNow.call(session)

    session.reload
    SpotSessionHold::METADATA_KEYS.each do |key|
      assert_nil session.metadata[key], "#{key} promises a re-check that is no longer what starts this session"
    end
  end

  # A turn already due is a turn on its way. Moving it would be pointless and
  # enqueuing another would be a second turn — so it is left exactly where it is,
  # and the answer is still "starting now".
  test "a turn that is already due is left alone rather than duplicated" do
    session = held_session
    job = queued_turn(session, scheduled_at: 2.minutes.ago)
    was = job.scheduled_at

    result = assert_no_enqueued_jobs(only: AgentSessionJob) do
      Sessions::StartNow.call(session)
    end

    assert result.started?, result.message
    assert_equal was.to_i, job.reload.scheduled_at.to_i
  end

  # A monitoring re-attach and a clone-only setup are not turns, so neither is
  # what a human means by "start it" — and pulling one forward would report a
  # start that spends nothing.
  test "a monitoring job is not mistaken for a queued turn" do
    session = held_session(session_id: "cli-abc")
    job = queued_turn(
      session,
      scheduled_at: 30.minutes.from_now,
      arguments: [ session.id, nil, { "resume_monitoring" => true, "_aj_symbol_keys" => [ "resume_monitoring" ] } ]
    )
    was = job.scheduled_at

    result = Sessions::StartNow.call(session)

    assert result.nothing_queued?, result.message
    assert_equal was.to_i, job.reload.scheduled_at.to_i
  end

  test "another session's queued turn is not pulled forward" do
    session = held_session
    other = held_session
    job = queued_turn(other, scheduled_at: 40.minutes.from_now)
    was = job.scheduled_at

    Sessions::StartNow.call(session)

    assert_equal was.to_i, job.reload.scheduled_at.to_i
  end

  # --- a session that never started -------------------------------------------

  test "a session that has never run and has nothing queued gets its first turn" do
    session = waiting_session

    result = nil
    assert_enqueued_with(job: AgentSessionJob, args: [ session.id ]) do
      result = Sessions::StartNow.call(session)
    end

    assert result.started?, result.message
    assert session.logs.reload.any? { |log| log.content.include?("Started now") }
  end

  test "a session that has run before and has nothing queued is reported, not nudged" do
    session = waiting_session(session_id: "cli-abc")

    result = assert_no_enqueued_jobs(only: AgentSessionJob) do
      Sessions::StartNow.call(session)
    end

    assert result.nothing_queued?, result.message
    assert_match(/has run before/, result.message)
  end

  # --- a session dormant in the spot queue ------------------------------------

  test "a session the ceiling paused mid-run is resumed rather than re-enqueued blind" do
    session = waiting_session(session_id: "cli-abc", metadata: {
      SpotSessionPause::PAUSED_AT => 1.hour.ago.utc.iso8601,
      SpotSessionPause::PAUSED_REASON => "at_utilization_limit",
      SpotSessionPause::PAUSED_DETAIL => "Holding spot sessions: the 5-hour window spent its spot budget.",
      SpotSessionPause::PAUSED_COUNT => 1,
      "paused_by" => SpotSessionPause::PAUSED_BY
    })

    result = Sessions::StartNow.call(session)

    assert result.started?, result.message
    session.reload
    assert session.running?, "the resume is what gives a paused session its turn back"
    assert_nil session.metadata[SpotSessionPause::PAUSED_REASON], "the pause record goes with the pause"
  end

  # --- refusals ---------------------------------------------------------------

  test "a session asleep on a wake-up it has not reached is refused" do
    session = waiting_session(session_id: "cli-abc")
    Sessions::ScheduleWakeUp.call(
      session: session,
      wake_at: 2.hours.from_now.utc.strftime("%Y-%m-%dT%H:%M:%S"),
      prompt: "Check the build"
    )

    result = Sessions::StartNow.call(session)

    assert result.refused?, result.message
    assert_match(/paused/, result.message)
  end

  test "a running session is refused" do
    session = waiting_session
    session.update!(status: :running)

    result = Sessions::StartNow.call(session)

    assert result.refused?
    assert_match(/only a waiting session/, result.message)
  end

  test "a trashed session is refused" do
    session = waiting_session
    session.update!(status: :archived)

    result = Sessions::StartNow.call(session)

    assert result.refused?
    assert_match(/trash/, result.message)
  end
end
