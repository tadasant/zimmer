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

  setup do
    Session.where(status: :running).update_all(status: Session.statuses[:needs_input])
    GoodJob::Job.delete_all
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
  # session page says "stalled" while /quotas counts 0 overdue.
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
      five_hour: nil, weekly: nil, active_sessions: 5, fleet_cap: 5,
      accounts_read: 1, pool_size: 1,
      fleet_burn_usd_per_minute: 0.0, candidate_burn_usd_per_minute: 0.0
    )
  end
end
