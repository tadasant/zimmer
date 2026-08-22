# frozen_string_literal: true

require "test_helper"

# CanaryJob's only job is to be run, so what is worth testing is exactly that: it
# runs, it touches nothing, and nothing about it can defer it. The production
# deploy gate (`scripts/verify-job-drain-remote.sh` in `tadasant/tadasant-internal`)
# enqueues one onto every GoodJob queue after a cutover and fails the deploy if the
# worker does not claim and finish it, so a regression here reds a healthy deploy.
class CanaryJobTest < ActiveJob::TestCase
  # The queues the deploy gate fans the canary out across, and the negative priority
  # it uses so the canary jumps whatever backlog the cutover left behind.
  GATE_QUEUES = %w[default pollers triggers agents].freeze
  GATE_PRIORITY = -100

  test "performing the job does not raise, with or without a token" do
    assert_nothing_raised do
      CanaryJob.perform_now
      CanaryJob.perform_now("deploy-abc123")
    end
  end

  test "performing the job issues no database queries at all" do
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      next if payload[:name] == "SCHEMA" || payload[:cached]
      next if %w[BEGIN COMMIT ROLLBACK].include?(payload[:sql].to_s.strip.upcase)

      statements << payload[:sql]
    end

    CanaryJob.perform_now("deploy-abc123")

    assert_empty statements,
                 "CanaryJob must stay a no-op — a query here is a way for the deploy " \
                 "liveness gate to fail for a non-liveness reason:\n#{statements.join("\n")}"
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  test "performing the job enqueues no other work" do
    assert_no_enqueued_jobs do
      CanaryJob.perform_now("deploy-abc123")
    end
  end

  test "performing the job logs the token so a human can match a canary to its deploy" do
    log = StringIO.new
    previous_logger = Rails.logger
    Rails.logger = ActiveSupport::TaggedLogging.new(Logger.new(log))

    CanaryJob.perform_now("deploy-abc123")

    assert_includes log.string, "[CanaryJob] deploy-abc123"
  ensure
    Rails.logger = previous_logger
  end

  test "declares no concurrency control" do
    # A concurrency-limited job is DEFERRED rather than run, which the gate cannot
    # distinguish from a dead queue — it would fail deploys of a healthy fleet.
    assert_empty CanaryJob.good_job_concurrency_config,
                 "CanaryJob must not declare good_job_control_concurrency_with"
  end

  test "defaults to the default queue" do
    assert_equal "default", CanaryJob.new.queue_name
  end

  test "is enqueued and performed end to end through ActiveJob" do
    assert_enqueued_with(job: CanaryJob, args: [ "deploy-abc123" ]) do
      CanaryJob.perform_later("deploy-abc123")
    end

    assert_performed_jobs 1 do
      perform_enqueued_jobs(only: CanaryJob)
    end
  end

  test "the gate's fan-out enqueues onto every queue at negative priority" do
    GATE_QUEUES.each do |queue|
      assert_enqueued_with(job: CanaryJob, queue: queue, priority: GATE_PRIORITY) do
        CanaryJob.set(queue: queue, priority: GATE_PRIORITY).perform_later("deploy-abc123")
      end
    end

    assert_performed_jobs GATE_QUEUES.size do
      perform_enqueued_jobs(only: CanaryJob)
    end
  end

  # The end-to-end proof that matters to the gate: a real GoodJob row, claimed and
  # finished by GoodJob's own execution path rather than by ActiveJob's test adapter.
  test "a real GoodJob row is claimed and finished on every queue the gate uses" do
    with_good_job_adapter do
      GATE_QUEUES.each do |queue|
        token = "deploy-#{queue}"
        CanaryJob.set(queue: queue, priority: GATE_PRIORITY).perform_later(token)

        row = GoodJob::Job.where(job_class: "CanaryJob", queue_name: queue).order(:created_at).last
        assert_not_nil row, "no GoodJob row was written for the #{queue} queue"
        assert_equal GATE_PRIORITY, row.priority
        assert_nil row.finished_at, "the row should still be waiting for a worker"

        # Raises if the canary raises; returns quietly if it claimed nothing, which
        # the assertions below catch.
        GoodJob.perform_inline(queue)

        row.reload
        assert_not_nil row.performed_at, "GoodJob never claimed the canary on #{queue}"
        assert_not_nil row.finished_at, "the canary never finished on #{queue}"
        assert_nil row.error, "the canary errored on #{queue}: #{row.error}"
      end
    end
  end

  private

  def with_good_job_adapter
    previous = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = GoodJob::Adapter.new(execution_mode: :external)
    yield
  ensure
    ActiveJob::Base.queue_adapter = previous
  end
end
