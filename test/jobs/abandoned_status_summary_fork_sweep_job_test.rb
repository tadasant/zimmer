# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# Reaping a status-summary fork that was created and never given its turn.
#
# The must-NOT-reap cases carry as much weight here as the reap: the failure
# mode of an over-broad predicate is a session quietly disappearing, which
# nobody sees.
class AbandonedStatusSummaryForkSweepJobTest < ActiveSupport::TestCase
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

  def transcript_of(*texts)
    texts.each_with_index.map do |text, i|
      if i.even?
        JSON.generate({ "type" => "user", "message" => { "role" => "user", "content" => text }, "timestamp" => "2026-08-01T10:00:0#{i}Z" })
      else
        JSON.generate({ "type" => "assistant", "message" => { "role" => "assistant", "content" => [ { "type" => "text", "text" => text } ] }, "timestamp" => "2026-08-01T10:00:0#{i}Z" })
      end
    end.join("\n") + "\n"
  end

  # A fork exactly as ForkSessionService leaves it: `needs_input`, a transcript
  # that is the source's conversation truncated at the fork point, no job, no
  # pending prompt. Nothing has been dispatched to it.
  def undispatched_fork(age: 2.days, status: :needs_input, metadata: {}, **attrs)
    session = Session.create!(
      {
        prompt: "summarize",
        agent_runtime: "claude_code",
        status: status,
        git_root: "https://github.com/test/repo.git",
        branch: "main",
        transcript: transcript_of("Ship the thing", "Opened the PR"),
        metadata: {
          SessionStatusSummaryGenerator::FORK_MARKER => @source.id,
          "forked_at_message_index" => 1
        }.merge(metadata)
      }.merge(attrs)
    )
    session.update_columns(created_at: age.ago, updated_at: age.ago)
    session.reload
  end

  # A one-time wake armed against `session`, built the way StrandedSleepRescue's
  # own tests build one rather than by stubbing the predicate — a stub would
  # only assert that the job calls a method it visibly calls.
  def arm_wake!(session, at: 3.hours.from_now)
    Trigger.new(
      name: "Wake session ##{session.id}",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "you were waiting on something",
      reuse_session: true,
      last_session_id: session.id,
      trigger_conditions_attributes: [
        { condition_type: "schedule",
          configuration: { "scheduled_at" => at.utc.strftime("%Y-%m-%dT%H:%M:%S"), "timezone" => "UTC" } }
      ]
    ).save!(validate: true)
  end

  # --- the reap -------------------------------------------------------------

  test "archives a status-summary fork that was created and never given its prompt" do
    fork = undispatched_fork

    AbandonedStatusSummaryForkSweepJob.perform_now

    assert fork.reload.archived?, "the undispatched fork should have been archived"
    assert fork.logs.any? { |log|
      log.content.include?("Zimmer's status-summary fork cleanup (never dispatched)")
    }, "the archive should name this sweep as its actor"
  end

  test "reaps a fork that was parked in waiting without a recovery marker" do
    fork = undispatched_fork(status: :waiting)

    AbandonedStatusSummaryForkSweepJob.perform_now

    assert fork.reload.archived?
  end

  test "the reap records why on the fork's own timeline" do
    fork = undispatched_fork

    AbandonedStatusSummaryForkSweepJob.perform_now

    assert fork.logs.any? { |log| log.content.include?("never received its summary prompt") },
           "the fork should carry a log line explaining the archive"
  end

  # The exact shape of the fork in #730: taken at message index 0, so its whole
  # transcript is one line and the `+ 1` in the comparison is load-bearing.
  test "reaps a fork taken at message index 0 with a one-line transcript" do
    fork = undispatched_fork(
      age: 7.days,
      transcript: transcript_of("Ship the thing"),
      metadata: { "forked_at_message_index" => 0 }
    )

    AbandonedStatusSummaryForkSweepJob.perform_now

    assert fork.reload.archived?
  end

  # Archiving is not the point on its own — reclaiming the clone is. The archive
  # hook stamps the trash expiry the clone cleanup keys on, so assert the fork
  # actually landed on that path rather than merely changing status.
  test "the reaped fork is put on the clone-reclaim path" do
    fork = undispatched_fork

    AbandonedStatusSummaryForkSweepJob.perform_now

    fork.reload
    assert fork.archived?
    assert fork.archived_at.present?
    assert fork.trash_after.present?, "the archive must set the trash expiry the clone cleanup reads"
  end

  test "reaps every abandoned fork in one sweep" do
    forks = Array.new(3) { undispatched_fork }

    AbandonedStatusSummaryForkSweepJob.perform_now

    assert forks.all? { |fork| fork.reload.archived? }
  end

  # --- the must-not-reap cases ---------------------------------------------

  test "leaves a fork that was created moments ago alone" do
    fork = undispatched_fork(age: 5.minutes)

    AbandonedStatusSummaryForkSweepJob.perform_now

    refute fork.reload.archived?, "a fork younger than ABANDONED_AFTER must not be reaped"
  end

  test "leaves a fork alone right up to the age threshold" do
    fork = undispatched_fork(age: AbandonedStatusSummaryForkSweepJob::ABANDONED_AFTER - 1.minute)

    AbandonedStatusSummaryForkSweepJob.perform_now

    refute fork.reload.archived?
  end

  test "leaves a fork whose prompt is in flight alone" do
    fork = undispatched_fork(metadata: { "pending_follow_up_prompt" => "Write the Status panel" })

    AbandonedStatusSummaryForkSweepJob.perform_now

    refute fork.reload.archived?, "a stamped follow-up prompt means the fork DID receive its turn"
  end

  test "leaves a fork with a tracked job alone" do
    fork = undispatched_fork(running_job_id: "9f1c0b3e-0000-0000-0000-000000000000")

    AbandonedStatusSummaryForkSweepJob.perform_now

    refute fork.reload.archived?
  end

  test "leaves a fork that took its turn alone" do
    fork = undispatched_fork(
      transcript: transcript_of("Ship the thing", "Opened the PR", "Write the Status panel", "The PR is open.")
    )

    AbandonedStatusSummaryForkSweepJob.perform_now

    refute fork.reload.archived?, "a fork with messages past the fork point ran; harvest owns it"
  end

  test "leaves a running fork alone" do
    fork = undispatched_fork(status: :running)

    AbandonedStatusSummaryForkSweepJob.perform_now

    refute fork.reload.archived?, "a running fork belongs to CleanupOrphanedSessionsJob"
  end

  test "leaves a fork with no recorded fork point alone" do
    fork = undispatched_fork
    fork.update!(metadata: fork.metadata.except("forked_at_message_index"))

    AbandonedStatusSummaryForkSweepJob.perform_now

    refute fork.reload.archived?, "without a fork point there is no positive evidence of a missing turn"
  end

  test "leaves a fork in a frozen category alone" do
    category = Category.create!(name: "Parked #{SecureRandom.hex(3)}", is_frozen: true)
    fork = undispatched_fork(category: category)

    AbandonedStatusSummaryForkSweepJob.perform_now

    refute fork.reload.archived?
  end

  # A spot-held fork is the sharpest must-not-reap case in the file. The hold
  # takes CUSTODY of the turn: SpotSessionHold#hold! removes
  # `pending_follow_up_prompt` and `return_to_queue!` clears `running_job_id`, so
  # a held fork looks exactly like an abandoned one on every marker except the
  # hold's own — and it is waiting to run.
  test "leaves a spot-held fork alone" do
    fork = undispatched_fork(
      status: :waiting,
      metadata: {
        SpotSessionHold::HELD_REASON => "quota_window",
        SpotSessionHold::HELD_AT => 1.hour.ago.utc.iso8601,
        SpotSessionHold::HELD_RETRY_AT => 10.minutes.from_now.utc.iso8601
      }
    )

    AbandonedStatusSummaryForkSweepJob.perform_now

    refute fork.reload.archived?, "a spot-held fork is waiting to run, not abandoned"
  end

  test "leaves a fork parked by an auth outage alone" do
    fork = undispatched_fork(status: :waiting, metadata: { "auth_outage_reason" => "quota_exhausted" })

    AbandonedStatusSummaryForkSweepJob.perform_now

    refute fork.reload.archived?
  end

  test "leaves a fork paused by recovery alone" do
    fork = undispatched_fork(metadata: { "paused_by" => "recovery" })

    AbandonedStatusSummaryForkSweepJob.perform_now

    refute fork.reload.archived?, "a recovery-paused fork is CleanupOrphanedSessionsJob's to continue"
  end

  # The anti-join, and the reason it carries more weight than `running_job_id`:
  # a turn enqueued with a DELAY leaves `running_job_id` blank, because that
  # column is written from inside the job.
  test "leaves a fork with a delayed turn still queued for it alone" do
    fork = undispatched_fork
    GoodJob::Job.create!(
      job_class: "AgentSessionJob", queue_name: "agents", scheduled_at: 10.minutes.from_now,
      serialized_params: { "job_class" => "AgentSessionJob", "arguments" => [ fork.id ] }
    )

    AbandonedStatusSummaryForkSweepJob.perform_now

    refute fork.reload.archived?, "an unfinished AgentSessionJob means the turn is still coming"
  end

  test "leaves a fork asleep on an armed wake alone" do
    fork = undispatched_fork(status: :waiting)
    arm_wake!(fork)

    AbandonedStatusSummaryForkSweepJob.perform_now

    refute fork.reload.archived?
  end

  test "leaves a fork with a message still queued for it alone" do
    fork = undispatched_fork
    EnqueuedMessage.create!(session: fork, content: "Write the Status panel", position: 1, status: "pending")

    AbandonedStatusSummaryForkSweepJob.perform_now

    refute fork.reload.archived?, "archiving over a queued message strands it, and a caller-origin strand pages"
  end

  test "leaves a fork alone if anything has written to it recently" do
    fork = undispatched_fork
    fork.update_column(:updated_at, 1.minute.ago)

    AbandonedStatusSummaryForkSweepJob.perform_now

    refute fork.reload.archived?,
           "a fresh write is the window in which a dormant marker may have just been cleared"
  end

  test "leaves a fork put to sleep through the API alone" do
    fork = undispatched_fork(status: :waiting, metadata: { "deliberate_sleep_at" => 1.day.ago.utc.iso8601 })

    AbandonedStatusSummaryForkSweepJob.perform_now

    refute fork.reload.archived?, "the API sleep arms nothing and marks nothing else, so its marker is the evidence"
  end

  # --- the reap is confined to status-summary forks -------------------------

  test "never touches an ordinary session in the same state" do
    ordinary = Session.create!(
      prompt: "Ship the thing",
      agent_runtime: "claude_code",
      status: :needs_input,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      transcript: transcript_of("Ship the thing", "Opened the PR")
    )
    ordinary.update_column(:created_at, 30.days.ago)

    AbandonedStatusSummaryForkSweepJob.perform_now

    refute ordinary.reload.archived?, "an ordinary session is never this sweep's business"
  end

  test "never touches an ordinary fork of another session" do
    plain_fork = Session.create!(
      prompt: "Ship the thing",
      agent_runtime: "claude_code",
      status: :needs_input,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      transcript: transcript_of("Ship the thing", "Opened the PR"),
      metadata: { "forked_from_session_id" => @source.id, "forked_at_message_index" => 1 }
    )
    plain_fork.update_column(:created_at, 30.days.ago)

    AbandonedStatusSummaryForkSweepJob.perform_now

    refute plain_fork.reload.archived?, "a user-initiated fork carries no FORK_MARKER and is not in scope"
  end

  test "never touches an outcome-analysis session in the same state" do
    analysis = Session.create!(
      prompt: "Analyze",
      agent_runtime: "claude_code",
      status: :needs_input,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      transcript: transcript_of("Analyze", "Done"),
      metadata: { Session::OUTCOME_ANALYSIS_MARKER => @source.id, "forked_at_message_index" => 1 }
    )
    analysis.update_column(:created_at, 30.days.ago)

    AbandonedStatusSummaryForkSweepJob.perform_now

    refute analysis.reload.archived?
  end

  # --- the source session is not disturbed ----------------------------------

  test "the source session's summary record is left for the backstop to repair" do
    fork = undispatched_fork
    record = SessionStatusSummary.create!(
      session: @source, state: "pending", requested_at: 2.days.ago,
      requested_line_count: 2, fork_session: fork
    )

    AbandonedStatusSummaryForkSweepJob.perform_now

    assert fork.reload.archived?
    assert_equal "pending", record.reload.state,
                 "the sweep disposes of the fork only; the abandoned claim is StatusSummaryBackstopJob's"
    refute @source.reload.archived?
  end
end
