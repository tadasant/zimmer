# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# The job half of #423's trigger path. The end-to-end cases — a held backlog
# released, a demotion releasing nothing, a park and a frozen category left
# alone — live in TriggerSchedulingClassTest, which drives this job through the
# callback that enqueues it. What is here is what only the job can be asked
# directly: what it does with arguments the trigger no longer backs.
class TriggerPromotionReleaseJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  def held_session
    session = Session.create!(
      git_root: "https://github.com/t/r.git", prompt: "work",
      status: :waiting, scheduling_class: SessionGenesis::PRIORITY,
      metadata: {
        SpotSessionHold::HELD_AT => 5.minutes.ago.utc.iso8601,
        SpotSessionHold::HELD_REASON => "at_utilization_limit",
        SpotSessionHold::HELD_DETAIL => "Holding spot sessions: the weekly window is at its target.",
        SpotSessionHold::HELD_RETRY_AT => 55.minutes.from_now.utc.iso8601,
        SpotSessionHold::HELD_COUNT => 4
      }
    )
    job = GoodJob::Job.create!(
      active_job_id: SecureRandom.uuid, job_class: "AgentSessionJob", queue_name: "agents",
      scheduled_at: 55.minutes.from_now,
      serialized_params: { "job_class" => "AgentSessionJob", "arguments" => [ session.id ] }
    )
    [ session, job ]
  end

  test "an empty id list does nothing and does not look the trigger up" do
    Trigger.expects(:find_by).never

    assert_nothing_raised { TriggerPromotionReleaseJob.perform_now(123, []) }
    assert_nothing_raised { TriggerPromotionReleaseJob.perform_now(123, nil) }
  end

  # The ids are collected before the trigger's save commits and the job runs
  # afterwards, so the trigger can be gone by then. The sessions were still
  # promoted, so they are still released — only the sentence changes.
  test "a trigger deleted before the job runs still releases its sessions" do
    session, job = held_session

    TriggerPromotionReleaseJob.perform_now(999_999, [ session.id ])

    refute SpotSessionHold.held?(session.reload)
    assert_operator job.reload.scheduled_at, :<=, Time.current
    assert session.logs.reload.any? { |l| l.content.include?("a trigger scheduling-class change") },
      "the actor sentence falls back rather than the release being skipped"
  end

  # The ids are a snapshot of what the reclassification wrote. A session demoted
  # by hand in the window between the commit and this run is one somebody moved
  # deliberately, and a per-session choice outranks a trigger-wide one.
  test "a session no longer priority when the job runs is left alone" do
    session, job = held_session
    session.update!(scheduling_class: SessionGenesis::SPOT)

    TriggerPromotionReleaseJob.perform_now(1, [ session.id ])

    assert SpotSessionHold.held?(session.reload)
    assert_operator job.reload.scheduled_at, :>, Time.current
  end

  test "an auth-outage park is left to the pool's own recovery" do
    session, job = held_session
    session.update!(metadata: session.metadata.merge("auth_outage_reason" => "all_accounts_exhausted"))

    TriggerPromotionReleaseJob.perform_now(1, [ session.id ])

    assert_operator job.reload.scheduled_at, :>, Time.current,
      "the park has its own resume owner"
  end

  test "it runs off the maintenance lane, not in front of ordinary callbacks" do
    assert_equal "maintenance", TriggerPromotionReleaseJob.new.queue_name
  end
end
