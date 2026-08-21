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

  # The headless repair costs one small-model completion rather than a clone
  # copy and an account slot, so an outage — which makes every session at rest a
  # candidate at once — gets a higher ceiling than the fork path. It is still a
  # ceiling: a sweep must not turn a fleet-wide outage into an unbounded burst
  # of subprocesses.
  test "the headless path has its own, higher per-sweep cap" do
    (StatusSummaryBackstopJob::MAX_HEADLESS_PER_SWEEP + 3).times { at_rest }
    ClaudeAccount.update_all(status: ClaudeAccount.statuses[:quota_exceeded])

    assert_enqueued_jobs StatusSummaryBackstopJob::MAX_HEADLESS_PER_SWEEP, only: SessionStatusSummaryJob do
      StatusSummaryBackstopJob.perform_now
    end
    assert_operator StatusSummaryBackstopJob::MAX_HEADLESS_PER_SWEEP, :>,
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
end
