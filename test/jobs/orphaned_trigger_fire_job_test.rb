# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# End to end over the path that was silent: a trigger creates a session, the
# session dies at first start, and the drop announces itself.
#
# This is the 7844 scenario (#632). Before this, `fail` fired the `session_failed`
# ao_event, enqueued a push notification, and stopped — none of which says
# anything about the trigger's work item, which is spent and unreplaceable the
# moment the session exists.
class OrphanedTriggerFireJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @trigger = triggers(:enabled_slack_trigger)
  end

  def trigger_originated_session(status: :running, metadata: {},
                                 genesis: SessionGenesis::GITHUB_LABEL)
    Session.create!(
      prompt: "Rate https://github.com/tadasant/zimmer/pull/623 for merge.",
      git_root: "https://github.com/tadasant/zimmer.git",
      genesis: genesis,
      status: status,
      metadata: {
        "trigger_id" => @trigger.id,
        "trigger_name" => @trigger.name
      }.merge(metadata)
    )
  end

  # ── The fix ───────────────────────────────────────────────────────────────

  test "failing a trigger-originated session enqueues the report" do
    session = trigger_originated_session
    session.update!(metadata: session.metadata.merge(
      "failure_reason" => "process_failed",
      "exit_status" => "Runtime session id 08654678-c2b5-4a40-a6b1-115bcf085b70 is already in use"
    ))

    assert_enqueued_with(job: OrphanedTriggerFireJob, args: [ session.id ]) do
      session.fail!
    end
  end

  test "the whole path, from a trigger's session dying to the drop being announced" do
    session = trigger_originated_session
    session.update!(metadata: session.metadata.merge("failure_reason" => "process_failed"))

    alerted = nil
    AlertService.stubs(:raise_alert).with do |title, opts|
      alerted = [ title, opts[:details] ]
      true
    end.returns(true)

    perform_enqueued_jobs(only: OrphanedTriggerFireJob) { session.fail! }

    assert_equal "Trigger session failed with its work undone", alerted&.first
    assert_match(%r{https://github\.com/tadasant/zimmer/pull/623}, alerted.last)
    assert session.reload.metadata[OrphanedTriggerFire::REPORTED_AT_KEY].present?
    assert session.logs.any? { |log| log.content.include?("The fire that created it is spent") }
  end

  # ── What must not become noisy ────────────────────────────────────────────

  test "an ordinary session failure enqueues nothing" do
    session = Session.create!(
      prompt: "Something a human asked for in the web UI",
      git_root: "https://github.com/tadasant/zimmer.git",
      genesis: SessionGenesis::WEB_UI,
      status: :running
    )

    assert_no_enqueued_jobs(only: OrphanedTriggerFireJob) do
      session.fail!
    end
  end

  # A status-summary fork inherits its source's metadata, so six of them failed
  # behind 7844 on the same start bug. A fork is not a work item — it summarizes
  # a session — and `fail` harvests it down a branch that never reaches this
  # report at all.
  test "a status-summary fork of a trigger-originated session enqueues nothing" do
    source = trigger_originated_session(status: :needs_input)
    fork = trigger_originated_session(
      metadata: { SessionStatusSummaryGenerator::FORK_MARKER => source.id }
    )

    assert fork.status_summary_fork?

    assert_no_enqueued_jobs(only: OrphanedTriggerFireJob) do
      fork.fail!
    end
  end

  # A recurring schedule's next tick is its own retry, so its failure is not a
  # dropped work item and must not enqueue a report.
  test "a scheduled trigger's session failing enqueues nothing" do
    session = trigger_originated_session(genesis: SessionGenesis::SCHEDULE)

    assert_no_enqueued_jobs(only: OrphanedTriggerFireJob) do
      session.fail!
    end
  end

  # ── The job itself ────────────────────────────────────────────────────────

  test "the job is a no-op for a session that has since been deleted" do
    AlertService.expects(:raise_alert).never

    assert_nothing_raised { OrphanedTriggerFireJob.perform_now(999_999) }
  end

  test "the job re-checks the session, so a recovery between enqueue and run stays quiet" do
    session = trigger_originated_session(status: :failed)
    session.update_column(:status, Session.statuses[:running])

    AlertService.expects(:raise_alert).never

    OrphanedTriggerFireJob.perform_now(session.id)
    assert_nil session.reload.metadata[OrphanedTriggerFire::REPORTED_AT_KEY]
  end
end
