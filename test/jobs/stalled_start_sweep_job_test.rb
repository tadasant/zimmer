# frozen_string_literal: true

require "test_helper"

class StalledStartSweepJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    GoodJob::Job.delete_all
    Session.where(status: :waiting).update_all(status: Session.statuses[:needs_input])
  end

  test "the job restarts a session that has been waiting to start with no job behind it" do
    session = Session.create!(
      git_root: "https://github.com/tadasant/tadasant-internal.git",
      prompt: "gate the PR",
      genesis: SessionGenesis::GITHUB_LABEL,
      status: :waiting
    )
    stalled_for = StalledSessionStart::GRACE + 5.minutes
    session.update_columns(created_at: stalled_for.ago, updated_at: stalled_for.ago)

    assert_enqueued_with(job: AgentSessionJob, args: [ session.id ]) do
      StalledStartSweepJob.perform_now
    end
  end

  test "a pass with nothing to do enqueues nothing" do
    assert_no_enqueued_jobs(only: AgentSessionJob) do
      StalledStartSweepJob.perform_now
    end
  end

  # The cron enqueues on schedule whether or not the previous tick has run, so a
  # congested queue must not accumulate copies of a level-triggered sweep.
  # test/jobs/recurring_sweep_concurrency_test.rb holds this line across the whole
  # cron table; this is the local statement of it.
  test "only one copy of the sweep is ever outstanding" do
    assert_includes StalledStartSweepJob.ancestors, SingletonSweep
  end
end
