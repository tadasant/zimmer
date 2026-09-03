# frozen_string_literal: true

require "test_helper"

# The repair path behind the one automatic trigger: a session already at rest has
# no further transition to regenerate on, so a generation that never landed would
# otherwise leave the panel stale for as long as the session sits in the queue.
class StatusSummaryBackstopJobTest < ActiveJob::TestCase
  setup do
    # The fixtures seed sessions of their own; archiving them leaves this test in
    # sole control of the candidate set and of the per-sweep cap.
    Session.where(status: [ :needs_input, :failed ]).update_all(status: Session.statuses[:archived])
    # And of the `inference` lane's depth, which is now the sweep's enqueue
    # budget: a stray unclaimed row would silently shrink it.
    GoodJob::Job.delete_all
  end

  # A SessionStatusSummaryJob already queued and unclaimed on the `inference`
  # lane — the depth the sweep's admission gate reads. `perform_later` under the
  # :test adapter writes nothing here, so the lane is exactly what a test says
  # it is.
  def queue_summary_jobs(count)
    Array.new(count) do |index|
      GoodJob::Job.create!(
        job_class: "SessionStatusSummaryJob", queue_name: "inference",
        scheduled_at: 1.minute.ago,
        serialized_params: {
          "job_class" => "SessionStatusSummaryJob", "arguments" => [ -(index + 1) ]
        }
      )
    end
  end

  def at_rest(status: :needs_input, transcript: TRANSCRIPT, **attrs)
    Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Ship the thing",
      status: status,
      transcript: transcript,
      **attrs
    )
  end

  TRANSCRIPT = <<~JSONL
    {"type":"user","message":{"role":"user","content":"Ship the thing"}}
    {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Opened the PR"}]}}
  JSONL

  test "a session at rest with no summary at all gets one enqueued" do
    session = at_rest

    assert_enqueued_with(job: SessionStatusSummaryJob, args: [ session.id, { headless: false } ]) do
      StatusSummaryBackstopJob.perform_now
    end
  end

  # The wedge this exists for: a fork that was parked or died leaves a `failed`
  # record and a blurb describing an earlier point in the session, and nothing
  # else would ever try again.
  test "a session whose last generation failed is retried" do
    session = at_rest
    SessionStatusSummary.create!(
      session: session, state: "failed", summary: "An older, real summary.",
      transcript_line_count: 1, generated_at: 1.hour.ago,
      error: "The summary fork was parked before it could answer (quota_exhausted)."
    )

    assert_enqueued_with(job: SessionStatusSummaryJob, args: [ session.id, { headless: false } ]) do
      StatusSummaryBackstopJob.perform_now
    end
  end

  # A claim taken by a generation that never came back: `pending` past
  # PENDING_TIMEOUT, which SessionStatusSummary calls abandoned.
  test "a claim abandoned past the pending timeout is retried" do
    session = at_rest
    SessionStatusSummary.create!(
      session: session, state: "pending",
      requested_at: (SessionStatusSummary::PENDING_TIMEOUT + 5.minutes).ago,
      requested_line_count: 2
    )

    assert_enqueued_with(job: SessionStatusSummaryJob, args: [ session.id, { headless: false } ]) do
      StatusSummaryBackstopJob.perform_now
    end
  end

  test "a generation still in flight is left alone" do
    session = at_rest
    SessionStatusSummary.create!(
      session: session, state: "pending", requested_at: 1.minute.ago, requested_line_count: 2
    )

    assert_no_enqueued_jobs only: SessionStatusSummaryJob do
      StatusSummaryBackstopJob.perform_now
    end
  end

  # A summary that has fallen behind the conversation without a transition
  # following it — the shape session 6369 was found in, where the fork's answer
  # landed already describing an earlier point in the session.
  test "a ready summary that has fallen behind the transcript is regenerated" do
    session = at_rest
    SessionStatusSummary.create!(
      session: session, state: "ready", summary: "Where things stood a while ago.",
      transcript_line_count: 1, generated_at: 1.hour.ago
    )

    assert_enqueued_with(job: SessionStatusSummaryJob, args: [ session.id, { headless: false } ]) do
      StatusSummaryBackstopJob.perform_now
    end
  end

  test "a current summary costs nothing" do
    session = at_rest
    SessionStatusSummary.create!(
      session: session, state: "ready", summary: "Where things stand.",
      transcript_line_count: 2, generated_at: 1.minute.ago
    )

    assert_no_enqueued_jobs only: SessionStatusSummaryJob do
      StatusSummaryBackstopJob.perform_now
    end
  end

  # A forced Regenerate that then failed leaves the record `failed` with the last
  # real summary still in place and still CURRENT. An unforced retry would be
  # answered "Summary is current" without clearing the state, so treating
  # `failed` as its own repair trigger would re-enqueue this session every
  # interval forever, spending a slot the repairable sessions need.
  test "a failed record whose summary is still current is not retried" do
    session = at_rest
    SessionStatusSummary.create!(
      session: session, state: "failed", summary: "Where things stand.",
      transcript_line_count: 2, generated_at: 1.minute.ago,
      error: "The summary fork failed: process_failed"
    )

    assert_no_enqueued_jobs only: SessionStatusSummaryJob do
      StatusSummaryBackstopJob.perform_now
    end
  end

  test "a running session is not swept — it has a transition of its own coming" do
    at_rest(status: :running)

    assert_no_enqueued_jobs only: SessionStatusSummaryJob do
      StatusSummaryBackstopJob.perform_now
    end
  end

  test "a session with no transcript is not swept" do
    at_rest(transcript: nil)

    assert_no_enqueued_jobs only: SessionStatusSummaryJob do
      StatusSummaryBackstopJob.perform_now
    end
  end

  # A summary fork IS a session that comes to rest at needs_input. Sweeping one
  # would fork the fork.
  test "status summary forks are not swept" do
    source = at_rest
    at_rest(metadata: { SessionStatusSummaryGenerator::FORK_MARKER => source.id })
    SessionStatusSummary.create!(
      session: source, state: "ready", summary: "Current.", transcript_line_count: 2
    )

    assert_no_enqueued_jobs only: SessionStatusSummaryJob do
      StatusSummaryBackstopJob.perform_now
    end
  end

  # needs_input with a live process mid-turn, waiting on an approval — not a
  # session at rest, and nothing final to say about it yet.
  test "a session blocked on an elicitation is not swept" do
    at_rest(metadata: { "blocked_on_elicitation" => true })

    assert_no_enqueued_jobs only: SessionStatusSummaryJob do
      StatusSummaryBackstopJob.perform_now
    end
  end

  test "no more than MAX_PER_SWEEP sessions are repaired in one sweep" do
    (StatusSummaryBackstopJob::MAX_PER_SWEEP + 3).times { at_rest }

    assert_enqueued_jobs StatusSummaryBackstopJob::MAX_PER_SWEEP, only: SessionStatusSummaryJob do
      StatusSummaryBackstopJob.perform_now
    end
  end

  # Examining a session costs a transcript read, and repairing one costs a fork.
  # Neither is paid again until the interval has passed.
  test "a session examined in this sweep is not examined again by the next one" do
    at_rest

    StatusSummaryBackstopJob.perform_now
    clear_enqueued_jobs

    assert_no_enqueued_jobs only: SessionStatusSummaryJob do
      StatusSummaryBackstopJob.perform_now
    end
  end

  test "a session examined longer ago than the retry interval is picked up again" do
    session = at_rest
    StatusSummaryBackstopJob.perform_now
    clear_enqueued_jobs
    session.status_summary.update_columns(
      backstop_attempted_at: (StatusSummaryBackstopJob::RETRY_INTERVAL + 1.minute).ago
    )

    assert_enqueued_with(job: SessionStatusSummaryJob, args: [ session.id, { headless: false } ]) do
      StatusSummaryBackstopJob.perform_now
    end
  end

  # THE REGRESSION THIS FILE EXISTS FOR, SECOND EDITION.
  #
  # Re-forking into an empty pool produces one more parked fork holding one more
  # copy of a repository, so the sweep still must not fork during an outage. But
  # the first version of this job answered that by standing down entirely —
  # which gated the retry on the very resource whose absence caused the failure
  # being retried. On a deployment under sustained quota pressure the blurb was
  # then unreachable: the panel said "the summary fork was parked, it will be
  # retried" for hours, and the retry was the thing standing down.
  #
  # An outage must now change the MODE, not the outcome.
  test "an exhausted login pool switches the sweep to the headless path rather than standing it down" do
    session = at_rest
    ClaudeAccount.update_all(status: ClaudeAccount.statuses[:quota_exceeded])

    assert_enqueued_with(job: SessionStatusSummaryJob, args: [ session.id, { headless: true } ]) do
      StatusSummaryBackstopJob.perform_now
    end
  end

  test "a healthy login pool still repairs by forking" do
    session = at_rest
    ClaudeAccount.update_all(status: ClaudeAccount.statuses[:active])

    assert_enqueued_with(job: SessionStatusSummaryJob, args: [ session.id, { headless: false } ]) do
      StatusSummaryBackstopJob.perform_now
    end
  end

  # The headless repair costs one small-model completion rather than a clone copy
  # and an account slot, so an outage — which makes every session at rest a
  # candidate at once — is not held to the fork path's cost cap. What bounds it
  # instead is the lane it enqueues onto: an empty `inference` lane admits
  # LANE_DEPTH_CEILING repairs, which is more than MAX_PER_SWEEP.
  test "an outage repairs up to the lane's ceiling, past the fork cost cap" do
    (StatusSummaryBackstopJob::LANE_DEPTH_CEILING + 3).times { at_rest }
    ClaudeAccount.update_all(status: ClaudeAccount.statuses[:quota_exceeded])

    assert_enqueued_jobs StatusSummaryBackstopJob::LANE_DEPTH_CEILING, only: SessionStatusSummaryJob do
      StatusSummaryBackstopJob.perform_now
    end
    assert_operator StatusSummaryBackstopJob::LANE_DEPTH_CEILING, :>,
      StatusSummaryBackstopJob::MAX_PER_SWEEP
  end

  # A session with a current summary costs nothing on either path — the outage
  # raises the cap, it does not lower the bar for what gets repaired.
  test "an outage does not repair a session whose summary is already current" do
    session = at_rest
    SessionStatusSummary.create!(
      session: session, state: "ready", summary: "Where things stand.",
      transcript_line_count: 2, generated_at: 1.minute.ago
    )
    ClaudeAccount.update_all(status: ClaudeAccount.statuses[:quota_exceeded])

    assert_no_enqueued_jobs only: SessionStatusSummaryJob do
      StatusSummaryBackstopJob.perform_now
    end
  end

  # The fork cost cap is a budget for ONE path, not a reason to stop walking. On
  # a mixed fleet — one runtime's pool healthy, another's exhausted — breaking
  # when it filled would end the sweep on the first session of whichever kind
  # came first in `updated_at` order, starving the headless repairs behind it,
  # which cost neither a clone copy nor an account slot.
  test "a spent fork cost cap does not starve the headless path behind it" do
    ClaudeAccount.update_all(status: ClaudeAccount.statuses[:quota_exceeded])
    ClaudeAccount.create!(
      email: "codex@tadasant.com", runtime: "codex", status: :active, priority: 0,
      oauth_config: { "tokens" => { "access_token" => "t" } }
    )

    # Enough healthy-runtime sessions to fill the fork cap, ordered ahead of the
    # outage-path one, so a `break` on the filled cap would never reach it. The
    # lane still has headroom for all of them: the ceiling is above the cap.
    StatusSummaryBackstopJob::MAX_PER_SWEEP.times { at_rest(agent_runtime: "codex") }
    extra_fork = at_rest(agent_runtime: "codex")
    extra_fork.update_column(:updated_at, 2.hours.ago)
    outage = at_rest
    outage.update_column(:updated_at, 1.hour.ago)

    assert_enqueued_with(job: SessionStatusSummaryJob, args: [ outage.id, { headless: true } ]) do
      StatusSummaryBackstopJob.perform_now
    end
    assert_nil extra_fork.reload.status_summary&.backstop_attempted_at,
      "a session skipped for the spent fork cap keeps its retry interval"
  end

  # ---------------------------------------------------------------------------
  # The `inference` lane's admission gate (#776)
  #
  # Both repair paths enqueue a SessionStatusSummaryJob, and that job runs on a
  # two-thread lane against calls that can block for HEADLESS_TIMEOUT. The sweep
  # therefore sizes its budget from what the lane already holds, rather than from
  # a number picked when these enqueues shared the wide `default` lane.
  # ---------------------------------------------------------------------------

  # The regression itself: a lane already saturated used to be enqueued into
  # regardless, at ten repairs a sweep — 120 arrivals an hour into a lane that
  # drains at most 80 — and the backlog grew for as long as there was anything to
  # repair, DURING the outage the headless path exists to work around.
  test "a saturated inference lane admits nothing" do
    queue_summary_jobs(StatusSummaryBackstopJob::LANE_DEPTH_CEILING)
    sessions = Array.new(StatusSummaryBackstopJob::LANE_DEPTH_CEILING + 6) { at_rest }
    ClaudeAccount.update_all(status: ClaudeAccount.statuses[:quota_exceeded])

    assert_no_enqueued_jobs only: SessionStatusSummaryJob do
      StatusSummaryBackstopJob.perform_now
    end
    assert_equal 0, sessions.count { |session| session.reload.status_summary&.backstop_attempted_at },
      "a sweep the lane gated must not spend anyone's retry interval either"
  end

  # A lane over its ceiling — other producers can put it there — is a floor of
  # zero, not a negative budget that would wrap into something enqueueable.
  test "a lane past its ceiling admits nothing rather than going negative" do
    queue_summary_jobs(StatusSummaryBackstopJob::LANE_DEPTH_CEILING * 3)
    at_rest

    assert_no_enqueued_jobs only: SessionStatusSummaryJob do
      StatusSummaryBackstopJob.perform_now
    end
  end

  # The gate is headroom, not an on/off switch: a partly full lane is topped up
  # to the ceiling and no further.
  test "a partly full lane is topped up to the ceiling and no further" do
    already_queued = StatusSummaryBackstopJob::LANE_DEPTH_CEILING - 2
    queue_summary_jobs(already_queued)
    (StatusSummaryBackstopJob::LANE_DEPTH_CEILING + 4).times { at_rest }
    ClaudeAccount.update_all(status: ClaudeAccount.statuses[:quota_exceeded])

    assert_enqueued_jobs 2, only: SessionStatusSummaryJob do
      StatusSummaryBackstopJob.perform_now
    end
  end

  # The whole point of the gate, and the invariant it must not break: quota
  # depletion is budget pacing, not a failure signal, so the sweep paces — it
  # does not stand down. A lane that drains is a lane the very next sweep fills
  # again.
  test "the gate paces the sweep rather than standing it down" do
    queue_summary_jobs(StatusSummaryBackstopJob::LANE_DEPTH_CEILING)
    (StatusSummaryBackstopJob::LANE_DEPTH_CEILING + 4).times { at_rest }
    ClaudeAccount.update_all(status: ClaudeAccount.statuses[:quota_exceeded])

    assert_no_enqueued_jobs(only: SessionStatusSummaryJob) { StatusSummaryBackstopJob.perform_now }

    GoodJob::Job.delete_all # the lane drained

    assert_enqueued_jobs StatusSummaryBackstopJob::LANE_DEPTH_CEILING, only: SessionStatusSummaryJob do
      StatusSummaryBackstopJob.perform_now
    end
  end

  # Depth means work a new arrival would wait behind. A row a worker has already
  # claimed is being served, not waiting, and a finished row is neither.
  test "only unclaimed rows count against the lane's headroom" do
    claimed = queue_summary_jobs(StatusSummaryBackstopJob::LANE_DEPTH_CEILING)
    GoodJob::Job.where(id: claimed.map(&:id)).update_all(performed_at: 10.seconds.ago)
    finished = queue_summary_jobs(StatusSummaryBackstopJob::LANE_DEPTH_CEILING)
    GoodJob::Job.where(id: finished.map(&:id)).update_all(finished_at: 1.minute.ago)
    at_rest
    ClaudeAccount.update_all(status: ClaudeAccount.statuses[:quota_exceeded])

    assert_enqueued_jobs 1, only: SessionStatusSummaryJob do
      StatusSummaryBackstopJob.perform_now
    end
  end

  # The sweep yields to the work a person is waiting on: a forced Regenerate and
  # a transition's automatic refresh occupy exactly the thread a repair would.
  test "another producer's queued rows take the sweep's headroom" do
    other = at_rest
    GoodJob::Job.create!(
      job_class: "SessionStatusSummaryJob", queue_name: "inference", scheduled_at: 1.minute.ago,
      priority: SessionStatusSummaryJob::FORCED_PRIORITY,
      serialized_params: { "job_class" => "SessionStatusSummaryJob", "arguments" => [ other.id, { "force" => true } ] }
    )
    queue_summary_jobs(StatusSummaryBackstopJob::LANE_DEPTH_CEILING - 1)
    at_rest

    assert_no_enqueued_jobs only: SessionStatusSummaryJob do
      StatusSummaryBackstopJob.perform_now
    end
  end

  # SessionTitleJob shares these two threads, and sizing the gate against total
  # lane depth would let a title burst — 100 of them on 2026-09-02 — stand the
  # sweep down completely. Against its own class the sweep keeps its share.
  test "a burst of another class on the same lane does not stand the sweep down" do
    30.times do |index|
      GoodJob::Job.create!(
        job_class: "SessionTitleJob", queue_name: "inference", scheduled_at: 1.minute.ago,
        serialized_params: { "job_class" => "SessionTitleJob", "arguments" => [ -(index + 1) ] }
      )
    end
    (StatusSummaryBackstopJob::LANE_DEPTH_CEILING + 2).times { at_rest }
    ClaudeAccount.update_all(status: ClaudeAccount.statuses[:quota_exceeded])

    assert_enqueued_jobs StatusSummaryBackstopJob::LANE_DEPTH_CEILING, only: SessionStatusSummaryJob do
      StatusSummaryBackstopJob.perform_now
    end
  end

  # The fork path enqueues onto the same lane, so it answers to the same gate —
  # a cost cap below the ceiling is not a reason to skip the admission check.
  test "the fork path draws on the same lane headroom" do
    queue_summary_jobs(StatusSummaryBackstopJob::LANE_DEPTH_CEILING)
    StatusSummaryBackstopJob::MAX_PER_SWEEP.times { at_rest }
    ClaudeAccount.update_all(status: ClaudeAccount.statuses[:active])

    assert_no_enqueued_jobs only: SessionStatusSummaryJob do
      StatusSummaryBackstopJob.perform_now
    end
  end

  # The sizing itself, stated where a reader can check it against the issue's
  # arithmetic. The ceiling is one sweep interval of lane time expressed in jobs,
  # so the sweep's arrival rate can never exceed the lane's service rate.
  test "the ceiling is derived from the lane, not hand-picked" do
    threads = ConnectionBudget.good_job_queue_threads.fetch(:inference)
    timeout = SessionStatusSummaryGenerator::HEADLESS_TIMEOUT

    assert_equal threads * StatusSummaryBackstopJob::SWEEP_INTERVAL.to_i / timeout,
      StatusSummaryBackstopJob::LANE_DEPTH_CEILING

    arrivals_per_hour =
      StatusSummaryBackstopJob::LANE_DEPTH_CEILING *
      (1.hour.to_i / StatusSummaryBackstopJob::SWEEP_INTERVAL.to_i)
    service_per_hour = threads * (1.hour.to_i / timeout)

    assert_operator arrivals_per_hour, :<=, service_per_hour,
      "the sweep must never be able to arrive faster than the lane serves"
  end

  # A ceiling of zero would turn the sweep into the no-op its header argues
  # against, whatever the thread count or the timeout is set to.
  test "the ceiling never derives to zero" do
    assert_operator StatusSummaryBackstopJob::LANE_DEPTH_CEILING, :>=, 1
  end

  # SWEEP_INTERVAL is half the derivation, and it lives in a second file. A
  # cadence changed in one and not the other resizes the gate silently.
  test "SWEEP_INTERVAL matches the cron cadence that actually runs the sweep" do
    entry = CronSchedule::ENTRIES.values.find { |e| e[:class] == "StatusSummaryBackstopJob" }

    assert entry, "StatusSummaryBackstopJob should still be on the cron schedule"
    assert_equal "*/#{StatusSummaryBackstopJob::SWEEP_INTERVAL.to_i / 60} * * * *", entry[:cron]
  end

  # The corollary: a session skipped because its path's budget is spent must not
  # burn its retry interval on a cap it never got past.
  test "a session skipped for a spent budget keeps its retry interval" do
    sessions = Array.new(StatusSummaryBackstopJob::MAX_PER_SWEEP + 2) { at_rest }

    StatusSummaryBackstopJob.perform_now

    stamped = sessions.count { |session| session.reload.status_summary&.backstop_attempted_at.present? }
    assert_equal StatusSummaryBackstopJob::MAX_PER_SWEEP, stamped,
      "only the sessions the sweep actually got to should have been stamped"
  end
end
