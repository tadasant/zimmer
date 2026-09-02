# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# The single automatic trigger for the Status blurb — the session changing
# status — and the fact that a summary fork's own transitions are routed into
# harvesting rather than into the operator's action queue.
class SessionStatusSummaryTriggerTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    Log.any_instance.stubs(:broadcast_append_to_timeline)
    Session.any_instance.stubs(:broadcast_status_change)

    @session = Session.create!(
      prompt: "work",
      agent_runtime: "claude_code",
      status: :running,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      transcript: JSON.generate({ "type" => "user", "message" => { "role" => "user", "content" => "hi" } }) + "\n"
    )
  end

  teardown do
    Mocha::Mockery.instance.teardown
  end

  test "pausing to needs_input enqueues a summary refresh" do
    assert_enqueued_with(job: SessionStatusSummaryJob, args: [ @session.id ]) do
      @session.pause!
    end
  end

  test "failing enqueues a summary refresh" do
    assert_enqueued_with(job: SessionStatusSummaryJob, args: [ @session.id ]) do
      @session.fail!
    end
  end

  # The automatic trigger coalesces per session. A queued summary job computes
  # the line count it summarizes when it claims the record, so it already covers
  # this transition's transcript; a second one behind it would take an `inference`
  # thread to return "Summary is current". 90 of those were ready on 2026-09-02.
  test "pausing does not enqueue a second summary refresh while one is still queued" do
    GoodJob::Job.create!(
      job_class: "SessionStatusSummaryJob", queue_name: "inference", scheduled_at: 1.minute.from_now,
      serialized_params: { "job_class" => "SessionStatusSummaryJob", "arguments" => [ @session.id ] }
    )

    assert_no_enqueued_jobs(only: SessionStatusSummaryJob) do
      @session.pause!
    end
  end

  # A forced Regenerate that is still queued will regenerate from the current
  # transcript when it runs, so it stands in for the automatic refresh too.
  test "a queued forced regenerate also covers the automatic refresh" do
    GoodJob::Job.create!(
      job_class: "SessionStatusSummaryJob", queue_name: "inference", scheduled_at: Time.current,
      priority: SessionStatusSummaryJob::FORCED_PRIORITY,
      serialized_params: {
        "job_class" => "SessionStatusSummaryJob",
        "arguments" => [ @session.id, { "force" => true, "_aj_ruby2_keywords" => [ "force" ] } ]
      }
    )

    assert_no_enqueued_jobs(only: SessionStatusSummaryJob) do
      @session.pause!
    end
  end

  test "pausing enqueues a summary refresh again once the earlier one has finished" do
    GoodJob::Job.create!(
      job_class: "SessionStatusSummaryJob", queue_name: "inference", scheduled_at: 2.minutes.ago,
      finished_at: 1.minute.ago,
      serialized_params: { "job_class" => "SessionStatusSummaryJob", "arguments" => [ @session.id ] }
    )

    assert_enqueued_with(job: SessionStatusSummaryJob, args: [ @session.id ]) do
      @session.pause!
    end
  end

  # The coalescing lives at the automatic enqueue site, not on the job, so the
  # forced surfaces are untouched: a queued automatic refresh must never swallow
  # the operator's Regenerate.
  test "a forced regenerate still enqueues while an automatic refresh is queued" do
    GoodJob::Job.create!(
      job_class: "SessionStatusSummaryJob", queue_name: "inference", scheduled_at: 1.minute.from_now,
      serialized_params: { "job_class" => "SessionStatusSummaryJob", "arguments" => [ @session.id ] }
    )

    assert_enqueued_with(job: SessionStatusSummaryJob, args: [ @session.id, { force: true } ]) do
      SessionStatusSummaryJob.set(priority: SessionStatusSummaryJob::FORCED_PRIORITY)
                             .perform_later(@session.id, force: true)
    end
  end

  test "a session with no transcript does not enqueue a summary refresh" do
    @session.update_column(:transcript, nil)

    assert_no_enqueued_jobs(only: SessionStatusSummaryJob) do
      @session.pause!
    end
  end

  # The only automatic trigger is a status change. Resuming is a status change
  # into `running`, but "where things stand" is a question about a session that
  # has stopped — summarizing at the start of a turn spends a fork on an answer
  # the same turn invalidates.
  test "resuming does not enqueue a summary refresh" do
    @session.pause!

    assert_no_enqueued_jobs(only: SessionStatusSummaryJob) do
      @session.resume!
    end
  end

  test "a summary fork pausing harvests instead of refreshing, notifying, or titling" do
    fork = Session.create!(
      prompt: "summarize",
      agent_runtime: "claude_code",
      status: :running,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      transcript: "{}\n",
      metadata: { SessionStatusSummaryGenerator::FORK_MARKER => @session.id }
    )

    # Session creation itself enqueues title inference; the assertions below are
    # about what the PAUSE enqueues.
    clear_enqueued_jobs

    assert_enqueued_with(job: SessionStatusSummaryHarvestJob) do
      fork.pause!
    end
    assert_no_enqueued_jobs(only: SessionStatusSummaryJob)
    assert_no_enqueued_jobs(only: SessionTitleJob)
  end

  test "a summary fork failing harvests with the failed flag" do
    fork = Session.create!(
      prompt: "summarize",
      agent_runtime: "claude_code",
      status: :running,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      transcript: "{}\n",
      metadata: { SessionStatusSummaryGenerator::FORK_MARKER => @session.id }
    )

    assert_enqueued_with(job: SessionStatusSummaryHarvestJob, args: [ fork.id, { failed: true } ]) do
      fork.fail!
    end
  end

  # The job is the whole automatic path's entry point; it must pass both mode
  # flags through and must not raise on a session that has since been destroyed.
  test "the job forwards force to the generator" do
    SessionStatusSummaryGenerator.expects(:call)
      .with(session: instance_of(Session), force: true, headless: false)
      .returns(SessionStatusSummaryGenerator::Result.new(outcome: :started, message: "ok"))

    SessionStatusSummaryJob.perform_now(@session.id, force: true)
  end

  # The repair sweep during an auth outage, and the harvest of a fork that came
  # back with nothing, both ask for the pool-independent path through this job.
  test "the job forwards headless to the generator" do
    SessionStatusSummaryGenerator.expects(:call)
      .with(session: instance_of(Session), force: false, headless: true)
      .returns(SessionStatusSummaryGenerator::Result.new(outcome: :ready, message: "ok"))

    SessionStatusSummaryJob.perform_now(@session.id, headless: true)
  end

  test "the job discards a session that no longer exists" do
    id = @session.id
    @session.destroy!

    assert_nothing_raised { SessionStatusSummaryJob.perform_now(id) }
  end

  test "summary forks are excluded from the operator-visible session scope" do
    fork = Session.create!(
      prompt: "summarize",
      agent_runtime: "claude_code",
      status: :needs_input,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      metadata: { SessionStatusSummaryGenerator::FORK_MARKER => @session.id }
    )

    visible = Session.excluding_status_summary_forks
    assert_includes visible, @session
    assert_not_includes visible, fork
  end
end
