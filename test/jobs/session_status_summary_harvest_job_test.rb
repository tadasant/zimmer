# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# Lifting a finished summary fork's answer onto the source session.
class SessionStatusSummaryHarvestJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    Log.any_instance.stubs(:broadcast_append_to_timeline)
    Session.any_instance.stubs(:broadcast_status_change)

    @source = Session.create!(
      prompt: "Ship the thing",
      agent_runtime: "claude_code",
      status: :needs_input,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      transcript: transcript_of("Ship the thing", "Opened the PR")
    )
  end

  teardown do
    Mocha::Mockery.instance.teardown
  end

  # Two lines of "prior conversation" (index 0 and 1), then the summary request
  # and the fork's answer (index 2 and 3).
  def transcript_of(*texts)
    texts.each_with_index.map do |text, i|
      if i.even?
        JSON.generate({ "type" => "user", "message" => { "role" => "user", "content" => text }, "timestamp" => "2026-08-01T10:00:0#{i}Z" })
      else
        JSON.generate({ "type" => "assistant", "message" => { "role" => "assistant", "content" => [ { "type" => "text", "text" => text } ] }, "timestamp" => "2026-08-01T10:00:0#{i}Z" })
      end
    end.join("\n") + "\n"
  end

  def build_fork(answer: "The PR is open and CI is green.", forked_at: 1)
    Session.create!(
      prompt: "summarize",
      agent_runtime: "claude_code",
      status: :needs_input,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      transcript: transcript_of("Ship the thing", "Opened the PR", "Write the Status panel", answer),
      metadata: {
        SessionStatusSummaryGenerator::FORK_MARKER => @source.id,
        "forked_at_message_index" => forked_at
      }
    )
  end

  def pending_record(fork, line_count: 2)
    SessionStatusSummary.create!(
      session: @source, state: "pending", requested_at: Time.current,
      requested_line_count: line_count, fork_session: fork
    )
  end

  test "the fork's answer becomes the source session's summary" do
    fork = build_fork
    pending_record(fork)

    SessionStatusSummaryHarvestJob.perform_now(fork.id)

    record = @source.reload.status_summary
    assert_equal "ready", record.state
    assert_equal "The PR is open and CI is green.", record.summary
    assert_not_nil record.generated_at
  end

  # The line count that makes the summary "current" is the count as of the
  # request, not as of the harvest — the fork read the transcript at fork time.
  test "the recorded line count is the one captured when generation was requested" do
    fork = build_fork
    pending_record(fork, line_count: 2)
    @source.update_column(:transcript, transcript_of("a", "b", "c", "d"))

    SessionStatusSummaryHarvestJob.perform_now(fork.id)

    record = @source.reload.status_summary
    assert_equal 2, record.transcript_line_count
    assert_equal 2, record.messages_since(@source.reload.transcript_line_count)
  end

  test "only text the fork wrote after the fork point is harvested" do
    fork = build_fork(answer: "The PR is open and CI is green.")
    pending_record(fork)

    SessionStatusSummaryHarvestJob.perform_now(fork.id)

    assert_equal "The PR is open and CI is green.", @source.reload.status_summary.summary
    assert_no_match(/Opened the PR/, @source.status_summary.summary)
  end

  # The prompt asks for 2-3 sentences; this is the backstop for an agent that
  # answered with an essay, so the panel cannot push the page off screen.
  test "an over-long answer is truncated to the panel's cap" do
    fork = build_fork(answer: "word " * 1000)
    pending_record(fork)

    SessionStatusSummaryHarvestJob.perform_now(fork.id)

    stored = @source.reload.status_summary.summary
    assert_equal StatusSummaryAnswer::MAX_SUMMARY_CHARS, stored.length
    assert stored.end_with?("...")
  end

  test "a fork destroyed before harvest is a no-op, not an error" do
    fork = build_fork
    pending_record(fork)
    id = fork.id
    fork.destroy!

    assert_nothing_raised { SessionStatusSummaryHarvestJob.perform_now(id) }
    assert_equal "pending", @source.reload.status_summary.state
  end

  test "a fenced answer is unwrapped" do
    fork = build_fork(answer: "```markdown\nThe PR is open.\n```")
    pending_record(fork)

    SessionStatusSummaryHarvestJob.perform_now(fork.id)

    assert_equal "The PR is open.", @source.reload.status_summary.summary
  end

  test "the fork is archived once harvested, so its clone copy is reclaimed" do
    fork = build_fork
    pending_record(fork)

    SessionStatusSummaryHarvestJob.perform_now(fork.id)

    assert fork.reload.archived?
  end

  test "a failed fork records the failure and still gets archived" do
    fork = build_fork
    fork.update!(metadata: fork.metadata.merge("failure_reason" => "process_died"))
    pending_record(fork)

    SessionStatusSummaryHarvestJob.perform_now(fork.id, failed: true)

    record = @source.reload.status_summary
    assert_equal "failed", record.state
    assert_match(/process_died/, record.error)
    assert fork.reload.archived?
  end

  test "a failed fork records its exit status on the source summary" do
    fork = build_fork
    fork.update!(
      metadata: fork.metadata.merge(
        "failure_reason" => "process_failed",
        "exit_status" => "Resume failed and no prompt available for fresh start recovery"
      )
    )
    pending_record(fork)

    SessionStatusSummaryHarvestJob.perform_now(fork.id, failed: true)

    record = @source.reload.status_summary
    assert_equal "failed", record.state
    assert_equal(
      "The summary fork failed: process_failed — Resume failed and no prompt available for fresh start recovery",
      record.error
    )
    assert fork.reload.archived?
  end

  test "an exception-killed fork surfaces its exception message, not the bare word exception" do
    # The exception path writes failure_reason + exception_message and never an
    # exit_status, so folding in only the exit status would leave the panel showing
    # "The summary fork failed: exception" — as opaque as no detail at all.
    fork = build_fork
    fork.update!(
      metadata: fork.metadata.merge(
        "failure_reason" => "exception",
        "exception_message" => "ActiveRecord::RecordInvalid: Agent root is not in the catalog"
      )
    )
    pending_record(fork)

    SessionStatusSummaryHarvestJob.perform_now(fork.id, failed: true)

    assert_equal(
      "The summary fork failed: exception — ActiveRecord::RecordInvalid: Agent root is not in the catalog",
      @source.reload.status_summary.error
    )
  end

  test "a failed fork's recorded error is capped at the stored-error limit" do
    fork = build_fork
    fork.update!(
      metadata: fork.metadata.merge(
        "failure_reason" => "process_failed",
        "exit_status" => "x" * 5_000
      )
    )
    pending_record(fork)

    SessionStatusSummaryHarvestJob.perform_now(fork.id, failed: true)

    error = @source.reload.status_summary.error
    assert_equal SessionStatusSummary::MAX_ERROR_CHARS, error.length,
      "an arbitrarily long exit_status must not be stored verbatim on the panel"
    assert error.start_with?("The summary fork failed: process_failed — ")
  end

  test "a fork with no answer of its own records a failure" do
    fork = build_fork
    fork.update_column(:transcript, transcript_of("Ship the thing", "Opened the PR"))
    pending_record(fork)

    SessionStatusSummaryHarvestJob.perform_now(fork.id)

    assert_equal "failed", @source.reload.status_summary.state
  end

  # A forced regenerate while a fork was still running has already pointed the
  # record at a newer fork; the older fork's answer is stale before it is read.
  test "an answer from a superseded fork is dropped, and the fork is still cleaned up" do
    old_fork = build_fork(answer: "Stale answer.")
    new_fork = build_fork(answer: "Fresh answer.")
    pending_record(new_fork)

    SessionStatusSummaryHarvestJob.perform_now(old_fork.id)

    assert_equal "pending", @source.reload.status_summary.state
    assert_nil @source.status_summary.summary
    assert old_fork.reload.archived?
  end

  # A newer generation claims the record before it forks, so between its claim
  # and its copy finishing the record is `pending` and names NO fork. A slow
  # older fork answering in that window must not be adopted: its blurb would be
  # stored against the newer generation's requested_line_count and so render as
  # up to date, and the newer generation would find its claim gone.
  test "an answer arriving while a newer claim names no fork yet is dropped" do
    old_fork = build_fork(answer: "Stale answer.")
    record = pending_record(old_fork)
    record.update!(requested_at: Time.current, requested_line_count: 9, fork_session: nil)

    SessionStatusSummaryHarvestJob.perform_now(old_fork.id)

    record.reload
    assert_equal "pending", record.state, "the newer claim is left in flight"
    assert_nil record.summary
    assert_equal 0, record.transcript_line_count, "no stale blurb stamped with the newer line count"
    assert old_fork.reload.archived?, "the fork is still cleaned up"
  end
  # The failure mode this deployment actually hit. AuthOutageParkService parks a
  # session that has run out of login pool by letting it reach `pause!` — the
  # same transition a finished turn reaches — so the fork's pause looked like a
  # completed turn, and the last assistant text in its transcript was the CLI's
  # own refusal. 73 sessions ended up displaying one as their status.
  test "a parked fork's transcript is not harvested as an answer" do
    fork = build_fork(answer: "You've hit your session limit · resets 10pm (UTC)")
    fork.update_column(:metadata, fork.metadata.merge("auth_outage_reason" => "quota_exhausted"))
    pending_record(fork)

    SessionStatusSummaryHarvestJob.perform_now(fork.id)

    record = @source.reload.status_summary
    assert_equal "failed", record.state
    assert_nil record.summary, "the runtime's refusal must never be stored as the summary"
    assert_nil record.generated_at
    assert_match(/parked/i, record.error)
  end

  # The stamp is what made this permanent rather than merely wrong: a refusal
  # stored at the requested line count reads as CURRENT, so `stale?` is false and
  # no later generation — automatic, forced or swept — would replace it.
  test "a parked fork leaves the displayed summary stale rather than stamping it current" do
    fork = build_fork(answer: "You've hit your weekly limit · resets Aug 22, 11am (UTC)")
    fork.update_column(:metadata, fork.metadata.merge("auth_outage_reason" => "quota_exhausted"))
    @source.update_column(:transcript, transcript_of("a", "b", "c", "d"))
    record = pending_record(fork, line_count: 4)
    record.update!(summary: "An older, real summary.", transcript_line_count: 2)

    SessionStatusSummaryHarvestJob.perform_now(fork.id)

    record.reload
    assert_equal "An older, real summary.", record.summary, "the last real summary is kept"
    assert_equal 2, record.transcript_line_count, "not restamped at the requested count"
    assert record.stale?(@source.transcript_line_count), "so a repair can still write over it"
  end

  # A fork can also print the limit line and exit cleanly, before the pool has
  # anything left to rotate into and therefore before anything parks it. Then the
  # text is the only evidence there is.
  test "a refusal answer is rejected even with no park marker on the fork" do
    [
      "You've hit your session limit · resets 10pm (UTC)",
      "Not logged in · Please run /login"
    ].each do |refusal|
      fork = build_fork(answer: refusal)
      pending_record(fork)

      SessionStatusSummaryHarvestJob.perform_now(fork.id)

      record = @source.reload.status_summary
      assert_equal "failed", record.state, "#{refusal.inspect} was accepted as a summary"
      assert_nil record.summary
      record.destroy!
    end
  end

  # The refusal can arrive wrapped, or assembled from two content parts joined
  # with a blank line. The patterns are single-line, so the text is squished
  # before it is matched.
  test "a refusal split over two lines is still rejected" do
    fork = build_fork(answer: "You've hit your session limit\n· resets 10pm (UTC)")
    pending_record(fork)

    SessionStatusSummaryHarvestJob.perform_now(fork.id)

    record = @source.reload.status_summary
    assert_equal "failed", record.state
    assert_nil record.summary
  end

  # The guard is a single short line matching a refusal, not the words anywhere:
  # a real blurb about a session that ran out of quota is a real blurb.
  test "a genuine summary that talks about hitting a limit is still stored" do
    answer = "A background subagent checking the backstop warning died when the account " \
             "hit your weekly limit, so that question resets to open — see " \
             "[message 12](https://zimmer.example.com/sessions/1#message-12). Nothing needs a human."
    fork = build_fork(answer: answer)
    pending_record(fork)

    SessionStatusSummaryHarvestJob.perform_now(fork.id)

    record = @source.reload.status_summary
    assert_equal "ready", record.state
    assert_equal answer, record.summary
  end

  test "a parked fork is still archived, so its clone copy is reclaimed" do
    fork = build_fork(answer: "You've hit your session limit · resets 10pm (UTC)")
    fork.update_column(:metadata, fork.metadata.merge("auth_outage_reason" => "quota_exhausted"))
    pending_record(fork)

    SessionStatusSummaryHarvestJob.perform_now(fork.id)

    assert fork.reload.archived?
  end

  # --- The fallback that makes a parked fork recoverable --------------------
  #
  # A parked fork means the pool is empty, which is exactly when waiting for the
  # next sweep to re-fork produces one more parked fork instead of a blurb. The
  # harvest hands the session straight to the path that needs no pool.

  # The park is its own evidence that a fork cannot deliver, so this does not
  # depend on what the pool looks like by the time the harvest runs — an account
  # may well have recovered in between.
  test "a parked fork hands the session to the pool-independent path" do
    fork = build_fork(answer: "You've hit your session limit · resets 10pm (UTC)")
    fork.update_column(:metadata, fork.metadata.merge("auth_outage_reason" => "quota_exhausted"))
    pending_record(fork)
    ClaudeAccount.update_all(status: ClaudeAccount.statuses[:active])

    assert_enqueued_with(job: SessionStatusSummaryJob, args: [ @source.id, { headless: true } ]) do
      SessionStatusSummaryHarvestJob.perform_now(fork.id)
    end
  end

  test "a fork that died while the pool was empty also hands the session to the headless path" do
    fork = build_fork
    pending_record(fork)
    ClaudeAccount.update_all(status: ClaudeAccount.statuses[:quota_exceeded])

    assert_enqueued_with(job: SessionStatusSummaryJob, args: [ @source.id, { headless: true } ]) do
      SessionStatusSummaryHarvestJob.perform_now(fork.id, failed: true)
    end
  end

  # A fork that died of something else — a crashed process, an MCP boot failure —
  # while the pool was healthy is NOT a case a fork cannot deliver. Downgrading
  # it would stamp a terser blurb as CURRENT and stop the sweep ever re-forking,
  # so the session keeps the degraded summary for good.
  test "a fork that died while the pool was healthy is left for the sweep to re-fork" do
    fork = build_fork
    pending_record(fork)
    ClaudeAccount.update_all(status: ClaudeAccount.statuses[:active])

    assert_no_enqueued_jobs only: SessionStatusSummaryJob do
      SessionStatusSummaryHarvestJob.perform_now(fork.id, failed: true)
    end
  end

  test "a fork that answered costs no headless retry" do
    fork = build_fork(answer: "The PR is open and CI is green.")
    pending_record(fork)

    assert_no_enqueued_jobs only: SessionStatusSummaryJob do
      SessionStatusSummaryHarvestJob.perform_now(fork.id)
    end
  end

  # A superseded fork returns before `text` is ever computed: another generation
  # owns this record, so retrying it here would race the runner that does.
  test "a superseded fork does not trigger a headless retry" do
    fork = build_fork
    other = build_fork
    pending_record(other)

    assert_no_enqueued_jobs only: SessionStatusSummaryJob do
      SessionStatusSummaryHarvestJob.perform_now(fork.id)
    end
  end
end
