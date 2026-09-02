# frozen_string_literal: true

require "test_helper"

# "Start it now": the operation behind the Ranked view's Start entry, and behind
# a promote to priority. The property that matters most is the one about NOT
# enqueuing — a held session already has its turn queued, and a second job for
# the same session is a second turn nobody asked for.
class Sessions::StartNowTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include AttachmentFixtures

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

  teardown { cleanup_stored_attachments! }

  # The arguments of the one AgentSessionJob this start enqueued.
  def enqueued_agent_session_args
    jobs = enqueued_jobs.select { |job| job["job_class"] == "AgentSessionJob" }
    assert_equal 1, jobs.length, "expected exactly one enqueued AgentSessionJob"
    ActiveJob::Arguments.deserialize(jobs.first["arguments"])
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

    result = nil
    assert_no_enqueued_jobs(only: AgentSessionJob) do
      result = Sessions::StartNow.call(session)
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

    result = nil
    assert_no_enqueued_jobs(only: AgentSessionJob) do
      result = Sessions::StartNow.call(session)
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

  # --- the first turn's attachments -------------------------------------------
  #
  # AgentSessionJob reads images and files ONLY out of its job arguments, so the
  # one branch that builds a job out of nothing has to rebuild the attachments
  # too. Enqueuing without them started a session whose prompt was "here is the
  # screenshot, fix this" with the prompt and without the screenshot (#739).

  test "a first turn is enqueued carrying the images the session was created with" do
    session = waiting_session
    stored = store_image_for(session)

    Sessions::StartNow.call(session)

    args = enqueued_agent_session_args
    assert_equal [ { path: stored[:path], media_type: "image/png" } ], args.dig(2, :images)
    assert_nil args.dig(2, :files)
  end

  test "a first turn is enqueued carrying the files the session was created with" do
    session = waiting_session
    stored = store_file_for(session, filename: "notes.txt", content: "read me")

    Sessions::StartNow.call(session)

    files = enqueued_agent_session_args.dig(2, :files)
    assert_equal [ stored[:path] ], files.map { |f| f[:path] }
    assert_equal [ "notes.txt" ], files.map { |f| f[:original_filename] }
    assert_equal [ "read me".bytesize ], files.map { |f| f[:size] }
  end

  # The ordinary case, and the one this must not change: no storage directory at
  # all, so the job is enqueued exactly as it was before.
  test "a session with no stored attachments is enqueued with no attachment arguments" do
    session = waiting_session

    result = nil
    assert_enqueued_with(job: AgentSessionJob, args: [ session.id ]) do
      result = Sessions::StartNow.call(session)
    end

    assert result.started?, result.message
    refute_match(/carrying/, result.message)
  end

  # Both kinds of attachment live in the same per-session directory, so
  # "everything on disk" is not the same set as "what the first turn carried".
  test "an attachment a queued follow-up owns is not smuggled onto the first turn" do
    session = waiting_session
    first_turn = store_image_for(session)
    follow_up = store_image_for(session)
    session.enqueued_messages.create!(
      content: "and now this one", position: 1,
      images: [ { "path" => follow_up[:path], "media_type" => "image/png" } ]
    )

    Sessions::StartNow.call(session)

    assert_equal [ { path: first_turn[:path], media_type: "image/png" } ],
      enqueued_agent_session_args.dig(2, :images)
  end

  # A turn short an attachment is a worse turn; a turn carrying somebody else's
  # is a wrong one. An unreadable queue therefore falls back to the former.
  test "an unreadable message queue falls back to a turn with no attachments" do
    session = waiting_session
    store_image_for(session)

    session.stub(:enqueued_messages, ->(*) { raise ActiveRecord::StatementInvalid, "boom" }) do
      Sessions::StartNow.call(session)
    end

    assert_equal [ session.id ], enqueued_agent_session_args,
      "a queue that cannot be read must not produce a duplicate attachment"
  end

  test "the session's log names what the first turn is carrying" do
    session = waiting_session
    store_image_for(session)
    store_file_for(session, filename: "notes.txt", content: "read me")

    result = Sessions::StartNow.call(session)

    assert_match(/carrying 1 image and 1 file/, result.message)
    assert session.logs.reload.any? { |log| log.content.include?("carrying 1 image and 1 file") }
  end

  # The other two branches move a job that already carries its own arguments.
  # Re-reading storage for them would attach a second copy.
  test "a pulled-forward turn is not given a second copy of the attachments" do
    session = held_session
    store_image_for(session)
    job = queued_turn(session, scheduled_at: 40.minutes.from_now)

    result = nil
    assert_no_enqueued_jobs(only: AgentSessionJob) do
      result = Sessions::StartNow.call(session)
    end

    assert result.started?, result.message
    refute_match(/carrying/, result.message)
    assert_equal [ session.id ], job.reload.serialized_params["arguments"],
      "the queued job's own arguments are the turn's attachments; nothing here rewrites them"
  end

  test "a resume from the spot queue does not re-read storage" do
    session = waiting_session(session_id: "cli-abc", metadata: {
      SpotSessionPause::PAUSED_AT => 1.hour.ago.utc.iso8601,
      SpotSessionPause::PAUSED_REASON => "at_utilization_limit",
      SpotSessionPause::PAUSED_DETAIL => "Holding spot sessions: the 5-hour window spent its spot budget.",
      SpotSessionPause::PAUSED_COUNT => 1,
      "paused_by" => SpotSessionPause::PAUSED_BY
    })
    store_image_for(session)

    result = Sessions::StartNow.call(session)

    assert result.started?, result.message
    refute_match(/carrying/, result.message)
  end

  test "a session that has run before and has nothing queued is reported, not nudged" do
    session = waiting_session(session_id: "cli-abc")

    result = nil
    assert_no_enqueued_jobs(only: AgentSessionJob) do
      result = Sessions::StartNow.call(session)
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

  # --- what a start actually promises -----------------------------------------

  # Moving a turn is not the same as passing the gate. A row of buttons that each
  # claim a start and deliver a re-check is worse than one that says what it did.
  test "a spot session is told the gate still decides" do
    session = held_session
    queued_turn(session, scheduled_at: 40.minutes.from_now)

    result = Sessions::StartNow.call(session)

    assert result.started?, result.message
    assert_match(/next turn is due now/, result.message)
    assert_match(/the gate decides/, result.message)
  end

  test "a priority session is told plainly that it is starting" do
    session = held_session
    session.update!(scheduling_class: SessionGenesis::PRIORITY)
    queued_turn(session, scheduled_at: 40.minutes.from_now)

    result = Sessions::StartNow.call(session)

    assert result.started?, result.message
    refute_match(/the gate decides/, result.message)
  end

  # The one confusion that produces the duplicate turn this class exists to
  # prevent: an unreadable queue looks exactly like an empty one, and a held
  # first-turn session (blank session_id) is the shape that would take the
  # enqueue branch on the strength of it.
  test "a queue that cannot be read is refused rather than read as empty" do
    session = held_session
    queued_turn(session, scheduled_at: 40.minutes.from_now)

    result = nil
    GoodJob::Job.stub(:where, ->(*) { raise ActiveRecord::StatementInvalid, "boom" }) do
      assert_no_enqueued_jobs(only: AgentSessionJob) do
        result = Sessions::StartNow.call(session)
      end
    end

    assert result.refused?, result.message
    assert_match(/Could not read what is queued/, result.message)
    assert_equal 3, session.reload.metadata[SpotSessionHold::HELD_COUNT],
      "a refused start must not reset the backoff ladder"
  end

  # The hold record explains why a dormant session is dormant. Clearing it for a
  # start that did not happen leaves an idle session with no banner and no reason.
  test "a session with nothing queued keeps the hold record explaining it" do
    session = held_session(session_id: "cli-abc")

    result = Sessions::StartNow.call(session)

    assert result.nothing_queued?, result.message
    assert_equal 3, session.reload.metadata[SpotSessionHold::HELD_COUNT]
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
