# frozen_string_literal: true

require "test_helper"

# The ladder repair. A spot hold is a promise ("re-checking at HH:MM") kept by
# exactly one delayed job, so losing that job strands the session in `waiting`
# forever — which is what happened to production session 7507 on 2026-08-31
# (tadasant/zimmer#648): the worker died between the hold record committing and
# its re-check being enqueued, and eleven hours later the page was still showing
# a human "5 of 5 session slots taken" from a gate reading taken at 02:12Z.
#
# Every test here is about the durable record — `spot_hold_retry_at` on the
# session — being what the ladder rests on, rather than one job surviving.
class SpotSessionHoldSweepTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include AttachmentFixtures

  setup do
    Session.where(status: :running).update_all(status: Session.statuses[:needs_input])
    GoodJob::Job.delete_all
  end

  teardown { cleanup_stored_attachments! }

  # The arguments of the one AgentSessionJob the sweep enqueued.
  def rearmed_agent_session_args
    jobs = enqueued_jobs.select { |job| job["job_class"] == "AgentSessionJob" }
    assert_equal 1, jobs.length, "expected exactly one enqueued AgentSessionJob"
    ActiveJob::Arguments.deserialize(jobs.first["arguments"])
  end

  def held_session(retry_at:, turn: SpotSessionHold::TURN_START, prompt: nil, extra: {})
    session = Session.create!(git_root: "https://github.com/t/r.git", prompt: "work",
                              genesis: SessionGenesis::GITHUB_ISSUE, status: :waiting)
    session.merge_metadata!({
      SpotSessionHold::HELD_AT => (retry_at - 30.minutes).utc.iso8601,
      SpotSessionHold::HELD_REASON => "fleet_at_cap",
      SpotSessionHold::HELD_DETAIL => "Holding spot sessions: 5 of 5 session slots taken.",
      SpotSessionHold::HELD_RETRY_AT => retry_at.utc.iso8601,
      SpotSessionHold::HELD_COUNT => 145,
      SpotSessionHold::HELD_TURN => turn
    }.merge(prompt ? { SpotSessionHold::HELD_PROMPT => prompt } : {}).merge(extra))
    session.reload
  end

  # The core defect: a hold whose re-check time has passed, with nothing
  # scheduled, must not stay stranded.
  test "sweep re-arms a held session whose re-check never fired" do
    session = held_session(retry_at: 11.hours.ago)

    result = nil
    assert_enqueued_with(job: AgentSessionJob) do
      result = SpotSessionHold.sweep!
    end

    assert_equal 1, result.rearmed
    assert_equal 1, result.overdue
    assert_equal 0, result.skipped

    session.reload
    rearmed_at = Time.zone.parse(session.metadata[SpotSessionHold::HELD_RETRY_AT])
    assert rearmed_at > Time.current - 1.second,
      "the re-check stamp must be advanced into the future so the ladder is armed again"
  end

  # The stamp is the sweep's own idempotency key: having re-armed once, a second
  # pass five minutes later must leave the session alone rather than stacking a
  # second job against the same turn.
  test "a re-armed session is not swept again on the next pass" do
    held_session(retry_at: 11.hours.ago)
    SpotSessionHold.sweep!
    GoodJob::Job.delete_all

    assert_no_enqueued_jobs(only: AgentSessionJob) do
      assert_equal 0, SpotSessionHold.sweep!.overdue
    end
  end

  # A re-check that is merely LATE is not a broken ladder. Inside the grace the
  # sweep keeps its hands off.
  test "a hold inside the overdue grace is left alone" do
    held_session(retry_at: (SpotSessionHold::OVERDUE_GRACE - 2.minutes).ago)

    assert_no_enqueued_jobs(only: AgentSessionJob) do
      assert_equal 0, SpotSessionHold.sweep!.overdue
    end
  end

  test "a hold whose re-check is still in the future is left alone" do
    held_session(retry_at: 20.minutes.from_now)

    assert_no_enqueued_jobs(only: AgentSessionJob) do
      assert_equal 0, SpotSessionHold.sweep!.overdue
    end
  end

  # A backed-up queue is not a lost job. If the re-check is still sitting in
  # GoodJob, re-arming would put a SECOND turn against the same session.
  test "a session whose re-check job is still queued is counted but not re-armed" do
    session = held_session(retry_at: 11.hours.ago)
    # Written straight into GoodJob rather than enqueued: the suite runs on the
    # ActiveJob test adapter, which persists nothing, and the pending-turn check
    # deliberately reads the durable queue rather than an in-memory one.
    GoodJob::Job.create!(
      job_class: "AgentSessionJob", queue_name: "agents", scheduled_at: 1.minute.from_now,
      serialized_params: { "job_class" => "AgentSessionJob", "arguments" => [ session.id ] }
    )
    enqueued_before = GoodJob::Job.count

    result = SpotSessionHold.sweep!

    assert_equal 0, result.rearmed
    assert_equal 1, result.overdue
    assert_equal 1, result.skipped
    assert_equal enqueued_before, GoodJob::Job.count, "no second job may be enqueued"
  end

  # A deferred RESUME's prompt used to exist only as the lost job's argument.
  # Recording it on the session is what lets the sweep replay the real turn.
  test "a re-armed resume carries the prompt the hold recorded" do
    session = held_session(retry_at: 11.hours.ago, turn: SpotSessionHold::TURN_RESUME,
                           prompt: "please continue the PR")

    SpotSessionHold.sweep!

    job = enqueued_jobs.find { |j| j["job_class"] == "AgentSessionJob" }
    assert_equal [ session.id, "please continue the PR" ], job["arguments"].first(2)
  end

  # Holds recorded before the prompt was durable — every session stranded today,
  # session 7507 included — have no prompt to replay. They must still come back.
  test "a re-armed resume with no recorded prompt falls back to a recovery nudge" do
    held_session(retry_at: 11.hours.ago, turn: SpotSessionHold::TURN_RESUME)

    SpotSessionHold.sweep!

    job = enqueued_jobs.find { |j| j["job_class"] == "AgentSessionJob" }
    assert AutomatedPrompts.system_recovery?(job["arguments"][1]),
      "a lost prompt must not stop the session coming back"
  end

  # --- a re-armed START carries the attachments the turn was created with ---
  #
  # `!resuming?` means the session has never run, so the job the sweep builds IS
  # the first turn. AgentSessionJob reads attachments ONLY out of its job
  # arguments, so enqueuing a bare one re-armed "here is the screenshot, fix
  # this" with the prompt and without the screenshot (#789), while the log line
  # below it told the reader the turn had been carried across.

  test "a re-armed start carries the images the session was created with" do
    session = held_session(retry_at: 11.hours.ago)
    image = store_image_for(session)

    assert_equal 1, SpotSessionHold.sweep!.rearmed

    assert_equal [ { path: image[:path], media_type: "image/png" } ],
      rearmed_agent_session_args.dig(2, :images)
    assert_match(/carrying 1 image/, session.logs.order(:id).last.content)
  end

  test "a re-armed start carries the files the session was created with" do
    session = held_session(retry_at: 11.hours.ago)
    stored = store_file_for(session, filename: "notes.txt", content: "read me")

    assert_equal 1, SpotSessionHold.sweep!.rearmed

    files = rearmed_agent_session_args.dig(2, :files)
    assert_equal [ stored[:path] ], files.map { |f| f[:path] }
    assert_equal [ "notes.txt" ], files.map { |f| f[:original_filename] }
  end

  # The ordinary case, and the one this must not change: nothing on disk, so the
  # job is enqueued exactly as it was before and the log says nothing extra.
  test "a re-armed start with no stored attachments is enqueued unchanged" do
    session = held_session(retry_at: 11.hours.ago)

    assert_equal 1, SpotSessionHold.sweep!.rearmed

    assert_equal [ session.id ], rearmed_agent_session_args
    refute_match(/carrying/, session.logs.order(:id).last.content)
  end

  # --- a re-armed RESUME carries the attachments the HOLD RECORD names ---
  #
  # The mirror image of the block above, and the reason it has to be a mirror
  # rather than a reuse: on a resume the volume holds every attachment the
  # session has ever received, so "everything on disk" would put a screenshot an
  # earlier turn already consumed onto this one. The descriptors `hold!` was
  # handed are written down with the prompt and replayed from there (#890).

  # Every attachment named here is STORED first, through the same service the
  # upload paths use, because the replay confirms the bytes are still on the
  # volume before it hands a path to the adapter. A record naming a file that has
  # been reaped is covered by its own test below.
  def recorded_resume(prompt:, images: [], files: [])
    session = held_session(retry_at: 11.hours.ago, turn: SpotSessionHold::TURN_RESUME,
                           prompt: prompt)
    stored_images = images.map { |name| store_image_for(session, filename: name) }
    stored_files = files.map { |name| store_file_for(session, filename: name, content: "read me") }
    session.merge_metadata!(
      { SpotSessionHold::HELD_IMAGES => stored_images.map { |i|
          { "path" => i[:path], "media_type" => i[:media_type] }
        } }.merge(
          stored_files.any? ? { SpotSessionHold::HELD_FILES => stored_files.map { |f|
            { "path" => f[:path], "original_filename" => f[:original_filename], "size" => f[:size] }
          } } : {}
        ).reject { |_, v| v.blank? }
    )
    [ session.reload, stored_images, stored_files ]
  end

  test "a re-armed resume carries the images the hold recorded" do
    session, images, = recorded_resume(prompt: "here is the screenshot, fix this",
                                       images: %w[shot.png])

    assert_equal 1, SpotSessionHold.sweep!.rearmed

    args = rearmed_agent_session_args
    assert_equal [ session.id, "here is the screenshot, fix this" ], args.first(2)
    assert_equal [ { path: images.first[:path], media_type: "image/png" } ], args.dig(2, :images)
    assert_match(/carrying 1 image/, session.logs.order(:id).last.content)
  end

  test "a re-armed resume carries the files the hold recorded" do
    session, _, files = recorded_resume(prompt: "read the notes", files: %w[notes.txt])

    assert_equal 1, SpotSessionHold.sweep!.rearmed

    assert_equal [ { path: files.first[:path], original_filename: "notes.txt", size: 7 } ],
      rearmed_agent_session_args.dig(2, :files)
    assert_match(/carrying 1 file/, session.logs.order(:id).last.content)
  end

  # The negative half, and the one that matters more: replaying the WRONG
  # attachments is worse than replaying none, because both are silent and only
  # one is also wrong. A resume's volume is full of turns it has already had.
  test "a re-armed resume does not pick up the volume's attachments" do
    session = held_session(retry_at: 11.hours.ago, turn: SpotSessionHold::TURN_RESUME,
                           prompt: "please continue the PR")
    store_image_for(session)

    assert_equal 1, SpotSessionHold.sweep!.rearmed

    assert_equal [ session.id, "please continue the PR" ], rearmed_agent_session_args
    log = session.logs.order(:id).last.content
    assert_match(/The prompt it was holding is carried with it\./, log)
    refute_match(/carrying/, log)
  end

  # And the sharper version: the hold record names ONE attachment while a second
  # one from a turn already consumed sits on the same volume. Both are genuinely
  # on disk, so only the record can tell them apart — exactly one may reach the
  # re-armed turn.
  test "a re-armed resume carries the recorded attachment and not the consumed one" do
    session, images, = recorded_resume(prompt: "here is the new screenshot, fix this",
                                       images: %w[new-shot.png])
    consumed = store_image_for(session, filename: "an-earlier-turns-shot.png")

    assert_equal 1, SpotSessionHold.sweep!.rearmed

    carried = rearmed_agent_session_args.dig(2, :images).map { |image| image[:path] }
    assert_equal [ images.first[:path] ], carried
    refute_includes carried, consumed[:path]
    assert_match(/carrying 1 image/, session.logs.order(:id).last.content)
  end

  # A lost prompt comes back as Zimmer's own sentence about a stalled ladder,
  # which is a different turn from the one the attachments were sent with. They
  # belong to the prompt that referred to them.
  test "a re-armed resume with no recorded prompt carries no attachments either" do
    session = held_session(retry_at: 11.hours.ago, turn: SpotSessionHold::TURN_RESUME)
    stored = store_image_for(session)
    session.merge_metadata!(
      SpotSessionHold::HELD_IMAGES => [ { "path" => stored[:path], "media_type" => "image/png" } ]
    )

    assert_equal 1, SpotSessionHold.sweep!.rearmed

    assert_equal 2, rearmed_agent_session_args.length,
      "a recovery nudge takes no attachments"
  end

  # The record outlives the files it names: the sweep re-arms records nobody has
  # touched for hours, while the durable-storage cleanup reaps a session's tree
  # on its own schedule. Handing the adapter a path that is gone is not a missing
  # screenshot — it `binread`s it, the ENOENT surfaces as a failed spawn, and the
  # session is stamped `spawn_failed`. A repair path must not be able to do more
  # damage than the thing it repairs.
  test "a replayed attachment whose file has been reaped is dropped, not replayed" do
    session = held_session(
      retry_at: 11.hours.ago, turn: SpotSessionHold::TURN_RESUME, prompt: "look at this",
      extra: { SpotSessionHold::HELD_IMAGES => [ { "path" => "/data/1/reaped.png",
                                                   "media_type" => "image/png" } ] }
    )

    assert_equal 1, SpotSessionHold.sweep!.rearmed

    assert_equal [ session.id, "look at this" ], rearmed_agent_session_args,
      "the turn comes back short an attachment rather than not at all"
    refute_match(/carrying/, session.logs.order(:id).last.content)
  end

  # A descriptor read back out of jsonb has string keys, and the CLI adapters
  # index it with symbols — so a replay that skipped the conversion would enqueue
  # a turn that looks like it carries a screenshot and reads as carrying none.
  test "a replayed descriptor arrives in the shape the adapters read" do
    session = held_session(retry_at: 11.hours.ago, turn: SpotSessionHold::TURN_RESUME,
                           prompt: "look")
    stored = store_image_for(session)
    session.merge_metadata!(
      SpotSessionHold::HELD_IMAGES => [ { "path" => stored[:path],
                                          "media_type" => "image/png",
                                          "unknown" => "dropped" } ]
    )

    SpotSessionHold.sweep!

    image = rearmed_agent_session_args.dig(2, :images).first
    assert_equal %i[path media_type], image.keys
    assert_equal stored[:path], image[:path]
  end

  test "a re-armed resume with no prompt still says the prompt was lost" do
    session = held_session(retry_at: 11.hours.ago, turn: SpotSessionHold::TURN_RESUME)

    assert_equal 1, SpotSessionHold.sweep!.rearmed

    assert_match(/lost with the re-check, so it comes back on a recovery nudge instead\./,
      session.logs.order(:id).last.content)
  end

  # A `start` hold is not always a first turn: McpOauthResumeService resumes an
  # already-run session with a promptless new-session job, which this gate can
  # hold. That session's lost job carried no attachments either, and everything
  # on its volume belongs to turns it has already had.
  test "a re-armed start for a session that has already run reads nothing off the volume" do
    session = held_session(retry_at: 11.hours.ago)
    session.update!(session_id: SecureRandom.uuid)
    store_image_for(session)

    assert_equal 1, SpotSessionHold.sweep!.rearmed

    assert_equal [ session.id ], rearmed_agent_session_args
    refute_match(/carrying/, session.logs.order(:id).last.content)
  end

  # A pause, an auth-outage park and a wall-clock pause each own their own
  # resume. Re-arming underneath one would start a session its owner stopped.
  test "a session also paused by the ceiling is not re-armed" do
    held_session(retry_at: 11.hours.ago,
                 extra: { SpotSessionPause::PAUSED_REASON => "at_utilization_limit" })

    assert_no_enqueued_jobs(only: AgentSessionJob) do
      assert_equal 0, SpotSessionHold.sweep!.rearmed
    end
  end

  test "a session also parked on an auth outage is not re-armed" do
    held_session(retry_at: 11.hours.ago, extra: { "auth_outage_reason" => "quota_exhausted" })

    assert_no_enqueued_jobs(only: AgentSessionJob) do
      assert_equal 0, SpotSessionHold.sweep!.rearmed
    end
  end

  # Only sessions dormant in `waiting` are on the ladder at all. An archived one
  # re-holding itself is a different defect (#630) and must not be revived here.
  test "only waiting sessions are swept" do
    session = held_session(retry_at: 11.hours.ago)
    session.update_columns(status: Session.statuses[:archived])

    assert_no_enqueued_jobs(only: AgentSessionJob) do
      assert_equal 0, SpotSessionHold.sweep!.overdue
    end
  end

  # A re-check due one second ago is a job that has not been picked up yet, not a
  # stalled ladder. Every surface has to draw that line in the same place, or the
  # session page says "stalled" while /inference counts 0 overdue.
  test "a hold overdue by seconds is neither swept nor described as stalled" do
    session = held_session(retry_at: 30.seconds.ago)

    assert_no_enqueued_jobs(only: AgentSessionJob) do
      assert_equal 0, SpotSessionHold.sweep!.overdue
    end
    assert_equal 0, SpotSessionHold.overdue_count
    refute SpotSessionHold.record_for(session).overdue?,
      "the banner and get_session read this same predicate — it must agree with the sweep"
  end

  # The starvation hole. A session dormant for a reason that outranks the hold is
  # refused every pass and never advances its stamp, so it stays overdue forever —
  # and `held_sessions` orders oldest-hold-first, walking exactly those sessions to
  # the head of the queue. If they consumed the batch, the sweep would never reach
  # a genuinely stranded session.
  test "sessions dormant for another reason do not consume the re-arm budget" do
    SpotSessionHold::MAX_REARMS_PER_SWEEP.times do
      held_session(retry_at: 20.hours.ago,
                   extra: { "auth_outage_reason" => "quota_exhausted" })
    end
    stranded = held_session(retry_at: 11.hours.ago)

    result = SpotSessionHold.sweep!

    assert_equal 1, result.rearmed, "the stranded session must still be reached"
    rearmed_at = Time.zone.parse(stranded.reload.metadata[SpotSessionHold::HELD_RETRY_AT])
    assert rearmed_at > Time.current - 1.second
  end

  # A hold record with no `spot_hold_detail` must not be a session #held? claims
  # and #record_for denies — that one would be counted and then silently refused
  # on every pass forever.
  test "a hold with no recorded detail is still a hold" do
    session = held_session(retry_at: 11.hours.ago)
    session.merge_metadata!({}, [ SpotSessionHold::HELD_DETAIL ])

    assert SpotSessionHold.held?(session.reload)
    assert_not_nil SpotSessionHold.record_for(session)
    assert_equal 1, SpotSessionHold.sweep!.rearmed
  end

  # A re-arm is a re-check, not an admission: the turn goes back through the gate,
  # which is free to refuse it again — with a fresh stamp behind it, so the ladder
  # is armed either way.
  test "a re-armed session the gate still refuses is held again with a fresh stamp" do
    session = held_session(retry_at: 11.hours.ago, turn: SpotSessionHold::TURN_RESUME,
                           prompt: "please continue")
    SpotSessionHold.sweep!

    # Past the re-armed stamp, which is when the re-armed job actually runs. The
    # gate is what decides then; a `fleet_at_cap` reading cannot refuse a session
    # already counted in the running fleet, so this is the utilization ceiling.
    session.update!(status: :running)
    held = nil
    travel_to(SpotSessionHold::REARM_SPREAD.from_now + 1.minute) do
      SpotGateService.stub(:evaluate, refusing_decision) do
        held = SpotSessionHold.hold_if_needed(session, follow_up_prompt: "please continue")
      end
    end

    assert held, "the gate still refuses it, so it is held again"
    session.reload
    assert_equal 146, session.metadata[SpotSessionHold::HELD_COUNT]
    assert Time.zone.parse(session.metadata[SpotSessionHold::HELD_RETRY_AT]) > Time.current
  end

  # The value comes from `follow_up_prompt` so it is a String in practice, but
  # `enqueue_with_prompt` raises on anything else — and it would raise AFTER the
  # stamp was advanced, leaving the session re-arming and failing on every pass.
  test "an unusable recorded prompt falls back to the recovery nudge" do
    held_session(retry_at: 11.hours.ago, turn: SpotSessionHold::TURN_RESUME,
                 extra: { SpotSessionHold::HELD_PROMPT => { "not" => "a string" } })

    assert_equal 1, SpotSessionHold.sweep!.rearmed

    job = enqueued_jobs.find { |j| j["job_class"] == "AgentSessionJob" }
    assert AutomatedPrompts.system_recovery?(job["arguments"][1])
  end

  test "one pass re-arms no more than MAX_REARMS_PER_SWEEP sessions" do
    (SpotSessionHold::MAX_REARMS_PER_SWEEP + 3).times { held_session(retry_at: 11.hours.ago) }

    result = SpotSessionHold.sweep!

    assert_equal SpotSessionHold::MAX_REARMS_PER_SWEEP, result.rearmed
    assert_equal SpotSessionHold::MAX_REARMS_PER_SWEEP + 3, result.overdue
  end

  # A sweep runs on the cron beside everything else; a pass that blew up would
  # take its retries with it, and the condition is re-read five minutes later.
  test "sweep never raises" do
    held_session(retry_at: 11.hours.ago)

    SpotSessionHold.stub(:overdue_sessions, ->(**) { raise "boom" }) do
      assert_equal 0, SpotSessionHold.sweep!.rearmed
    end
  end

  # === The reported population ===

  test "held_count counts sessions held before a turn, and overdue_count the stalled ladders" do
    held_session(retry_at: 20.minutes.from_now)
    held_session(retry_at: 11.hours.ago)

    assert_equal 2, SpotSessionHold.held_count
    assert_equal 1, SpotSessionHold.overdue_count
  end

  # The defect Tadas hit from the other side: `get_spot_policy` reported "asleep
  # in the spot queue: 0" while a held session was demonstrably asleep, because
  # the only figure it printed was the PAUSE population.
  test "a held session is invisible to the pause population and visible to the hold one" do
    held_session(retry_at: 11.hours.ago)

    assert_equal 0, SpotSessionPause.paused_count
    assert_equal 1, SpotSessionHold.held_count
  end

  # A session carrying BOTH records belongs to the pause population, which counts
  # and resumes it. Counting it here too would double-count it, and would promise
  # a repair the sweep refuses.
  test "a session that is also paused or parked is not in the held population" do
    held_session(retry_at: 11.hours.ago,
                 extra: { SpotSessionPause::PAUSED_REASON => "at_utilization_limit" })
    held_session(retry_at: 11.hours.ago, extra: { "auth_outage_reason" => "quota_exhausted" })

    assert_equal 0, SpotSessionHold.held_count
    assert_equal 0, SpotSessionHold.overdue_count
  end

  def refusing_decision
    SpotGateService::Decision.new(
      allowed: false, reason: SpotSessionHold::UTILIZATION_REASON,
      detail: "Holding spot sessions: the weekly window's spot budget is spent.",
      five_hour: nil, weekly: nil, active_sessions: 5, awaiting_sessions: 0, fleet_cap: 5,
      accounts_read: 1, pool_size: 1,
      fleet_burn_usd_per_minute: 0.0, candidate_burn_usd_per_minute: 0.0,
      pool_capacity: nil
    )
  end
end
