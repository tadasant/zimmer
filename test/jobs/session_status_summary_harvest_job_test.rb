# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# Lifting a finished summary fork's answer onto the source session.
class SessionStatusSummaryHarvestJobTest < ActiveSupport::TestCase
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
    assert_equal SessionStatusSummaryHarvestJob::MAX_SUMMARY_CHARS, stored.length
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
end
