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

    assert_enqueued_with(job: SessionStatusSummaryJob, args: [ session.id ]) do
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

    assert_enqueued_with(job: SessionStatusSummaryJob, args: [ session.id ]) do
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

    assert_enqueued_with(job: SessionStatusSummaryJob, args: [ session.id ]) do
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

    assert_enqueued_with(job: SessionStatusSummaryJob, args: [ session.id ]) do
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

    assert_enqueued_with(job: SessionStatusSummaryJob, args: [ session.id ]) do
      StatusSummaryBackstopJob.perform_now
    end
  end

  # Re-forking into an empty pool produces one more parked fork holding one more
  # copy of a repository — the exact waste that made the summaries wrong in the
  # first place.
  test "an exhausted login pool holds the sweep, without spending the retry interval" do
    session = at_rest
    ClaudeAccount.update_all(status: ClaudeAccount.statuses[:quota_exceeded])

    assert_no_enqueued_jobs only: SessionStatusSummaryJob do
      StatusSummaryBackstopJob.perform_now
    end
    assert_nil session.reload.status_summary&.backstop_attempted_at,
      "a session held back by an outage must not burn its retry interval"

    ClaudeAccount.update_all(status: ClaudeAccount.statuses[:active])

    assert_enqueued_with(job: SessionStatusSummaryJob, args: [ session.id ]) do
      StatusSummaryBackstopJob.perform_now
    end
  end
end
