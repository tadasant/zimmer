# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# The dangerous edges of a bulk destructive op on `good_jobs`.
#
# The failure this file exists to prevent is an over-broad scope predicate: it
# strands live sessions, it is not recoverable, and it fails silently — the call
# returns a happy count either way. So every clause of the predicate is asserted
# from the outside, with real rows, rather than trusted from a reading of the SQL.
class QueuedJobMaintenanceTest < ActiveSupport::TestCase
  include ErrorReporterHelpers

  setup do
    GoodJob::Job.delete_all
  end

  teardown do
    GoodJob::Job.delete_all
  end

  # A `good_jobs` row in whatever state the test needs. Built directly rather than
  # by enqueuing, because the states that matter here (started, claimed, finished,
  # discarded) are ones an enqueue cannot produce.
  def build_job(job_class: "CanaryJob", queue_name: "default", **attrs)
    id = SecureRandom.uuid

    GoodJob::Job.create!(
      id: id,
      active_job_id: id,
      job_class: job_class,
      queue_name: queue_name,
      priority: 0,
      scheduled_at: Time.current,
      serialized_params: {
        "job_class" => job_class, "job_id" => id, "queue_name" => queue_name,
        "priority" => 0, "arguments" => [], "executions" => 0, "locale" => "en"
      },
      **attrs
    )
  end

  # === The scope predicate ===

  test "finished rows are never eligible, so history cannot be rewritten" do
    finished = build_job(finished_at: 1.hour.ago, performed_at: 2.hours.ago)
    discarded = build_job(finished_at: 1.hour.ago, performed_at: 2.hours.ago, error: "StandardError: boom")
    waiting = build_job

    assert_equal [ waiting.id ], QueuedJobMaintenance.eligible(job_class: "CanaryJob").pluck(:id)

    QueuedJobMaintenance.discard!(job_class: "CanaryJob", expected_count: 1, actor: "test")

    # Untouched: same finished_at, same error, still in the history the dashboard reads.
    assert_equal finished.finished_at.to_i, finished.reload.finished_at.to_i
    assert_equal "StandardError: boom", discarded.reload.error
  end

  test "a running execution is never eligible" do
    running = build_job(performed_at: 5.minutes.ago)
    waiting = build_job

    assert_equal [ waiting.id ], QueuedJobMaintenance.eligible(job_class: "CanaryJob").pluck(:id)

    QueuedJobMaintenance.discard!(job_class: "CanaryJob", expected_count: 1, actor: "test")

    assert_nil running.reload.finished_at
  end

  test "a row a worker has claimed is never eligible" do
    claimed = build_job(locked_by_id: SecureRandom.uuid, locked_at: 1.minute.ago)
    build_job

    preview = QueuedJobMaintenance.preview(job_class: "CanaryJob")

    assert_equal 1, preview.matched
    refute_includes QueuedJobMaintenance.eligible(job_class: "CanaryJob").pluck(:id), claimed.id
  end

  test "a future-dated row IS eligible — it is backlog that has not come due yet" do
    scheduled = build_job(scheduled_at: 2.hours.from_now)

    assert_includes QueuedJobMaintenance.eligible(job_class: "CanaryJob").pluck(:id), scheduled.id
  end

  # === The agents refusal ===

  test "the agents queue is refused by name" do
    error = assert_raises(QueuedJobMaintenance::Refused) do
      QueuedJobMaintenance.discard!(queue_name: "agents", expected_count: 1, actor: "test")
    end

    assert_match(/protected/, error.message)
    assert_match(/live agent session/, error.message)
  end

  test "AgentSessionJob is refused by class" do
    error = assert_raises(QueuedJobMaintenance::Refused) do
      QueuedJobMaintenance.discard!(job_class: "AgentSessionJob", expected_count: 1, actor: "test")
    end

    assert_match(/IS a live session/, error.message)
  end

  test "the queue recovery mode expiry backstop is refused by class" do
    error = assert_raises(QueuedJobMaintenance::Refused) do
      QueuedJobMaintenance.discard!(job_class: "QueueRecoveryModeExpiryJob", expected_count: 1, actor: "test")
    end

    assert_match(/lifts queue recovery mode/, error.message)
  end

  test "rescheduling the agents queue is refused too, not only discarding" do
    assert_raises(QueuedJobMaintenance::Refused) do
      QueuedJobMaintenance.reschedule!(queue_name: "agents", expected_count: 1, actor: "test")
    end
  end

  # The refusal above is by name; this is the second, independent line. A scope
  # that never names `agents` still must not reach a session — which is what a
  # discard by job class alone, or by another queue, would do if the predicate
  # were the only thing standing in the way.
  test "a live session is untouched by a call that does not name agents at all" do
    session_job = build_job(job_class: "AgentSessionJob", queue_name: "agents")
    build_job(job_class: "CanaryJob", queue_name: "default")

    result = QueuedJobMaintenance.discard!(queue_name: "default", expected_count: 1, actor: "test")

    assert_equal 1, result.affected
    assert_nil session_job.reload.finished_at
  end

  test "the expiry backstop is untouched by a discard of its own queue" do
    backstop = build_job(job_class: "QueueRecoveryModeExpiryJob", queue_name: "agents")

    assert_raises(QueuedJobMaintenance::Refused) do
      QueuedJobMaintenance.discard!(queue_name: "agents", expected_count: 1, actor: "test")
    end

    assert_nil backstop.reload.finished_at
  end

  # === Count confirmation ===

  test "a count mismatch refuses and discards nothing" do
    3.times { build_job }

    error = assert_raises(QueuedJobMaintenance::Refused) do
      QueuedJobMaintenance.discard!(job_class: "CanaryJob", expected_count: 2, actor: "test")
    end

    assert_match(/Count confirmation failed/, error.message)
    assert_match(/you expected 2 rows, 3 match/, error.message)
    # The refusal doubles as the preview: it names the real count and the classes.
    assert_match(/CanaryJob=3/, error.message)
    assert_match(/expected_count=3/, error.message)
    assert_equal 0, GoodJob::Job.where.not(finished_at: nil).count
  end

  test "a missing count is a refusal, not a default" do
    build_job

    error = assert_raises(QueuedJobMaintenance::Refused) do
      QueuedJobMaintenance.discard!(job_class: "CanaryJob", expected_count: nil, actor: "test")
    end

    assert_match(/expected_count is required/, error.message)
    assert_nil GoodJob::Job.first.finished_at
  end

  test "a non-integral count is refused rather than truncated" do
    build_job

    assert_raises(QueuedJobMaintenance::Refused) do
      QueuedJobMaintenance.discard!(job_class: "CanaryJob", expected_count: 1.5, actor: "test")
    end
  end

  test "a count that arrives as a string is accepted — an HTML form sends one" do
    build_job

    result = QueuedJobMaintenance.discard!(job_class: "CanaryJob", expected_count: "1", actor: "test")

    assert_equal 1, result.affected
  end

  # === Cap ===

  test "a scope over the cap is refused, and the refusal says how big it is" do
    QueuedJobMaintenance.stubs(:preview).returns(
      QueuedJobMaintenance::Preview.new(
        job_class: "CanaryJob", queue_name: nil, matched: 5_000,
        by_job_class: { "CanaryJob" => 5_000 }, by_queue: { "default" => 5_000 }, over_cap: true
      )
    )

    error = assert_raises(QueuedJobMaintenance::Refused) do
      QueuedJobMaintenance.discard!(job_class: "CanaryJob", expected_count: 5_000, actor: "test")
    end

    assert_match(/5000 rows match/, error.message)
    assert_match(/#{QueuedJobMaintenance::MAX_PER_CALL}-row cap/, error.message)
    assert_match(/CanaryJob=5000/, error.message)
  end

  test "the cap is checked before the count, so an over-cap scope cannot be confirmed into" do
    QueuedJobMaintenance.stubs(:preview).returns(
      QueuedJobMaintenance::Preview.new(
        job_class: "CanaryJob", queue_name: nil, matched: 5_000,
        by_job_class: {}, by_queue: {}, over_cap: true
      )
    )

    error = assert_raises(QueuedJobMaintenance::Refused) do
      QueuedJobMaintenance.discard!(job_class: "CanaryJob", expected_count: 0, actor: "test")
    end

    assert_match(/cap/, error.message)
  end

  # === Unscoped ===

  test "a call that names neither a class nor a queue is refused" do
    build_job

    error = assert_raises(QueuedJobMaintenance::Refused) do
      QueuedJobMaintenance.discard!(expected_count: 1, actor: "test")
    end

    assert_match(/unscoped/, error.message)
    assert_nil GoodJob::Job.first.finished_at
  end

  test "blank strings do not count as a scope" do
    build_job

    assert_raises(QueuedJobMaintenance::Refused) do
      QueuedJobMaintenance.discard!(job_class: "  ", queue_name: "", expected_count: 1, actor: "test")
    end
  end

  # === What it did ===

  test "discard reports what it discarded, by class and by queue" do
    2.times { build_job(job_class: "CanaryJob", queue_name: "default") }
    build_job(job_class: "HeartbeatSweepJob", queue_name: "default")

    result = QueuedJobMaintenance.discard!(queue_name: "default", expected_count: 3, reason: "backlog", actor: "operator")

    assert_equal 3, result.affected
    assert_equal({ "CanaryJob" => 2, "HeartbeatSweepJob" => 1 }, result.by_job_class)
    assert_equal({ "default" => 3 }, result.by_queue)
    assert_equal "operator", result.actor
    refute result.as_json[:recoverable]
    assert_equal 3, GoodJob::Job.where.not(finished_at: nil).count
    assert GoodJob::Job.first.error.to_s.include?("backlog")
  end

  test "a discarded row is marked finished with a discard error, which is what makes it unrecoverable" do
    job = build_job

    QueuedJobMaintenance.discard!(job_class: "CanaryJob", expected_count: 1, actor: "test")

    job.reload
    assert job.finished_at.present?
    assert_match(/DiscardJobError/, job.error)
    assert job.discarded?
  end

  test "reschedule moves scheduled_at and leaves the row runnable" do
    job = build_job(scheduled_at: 1.hour.ago)
    target = 30.minutes.from_now

    result = QueuedJobMaintenance.reschedule!(job_class: "CanaryJob", expected_count: 1, scheduled_at: target, actor: "test")

    assert_equal 1, result.affected
    assert result.as_json[:recoverable]
    job.reload
    assert_nil job.finished_at
    assert_in_delta target.to_i, job.scheduled_at.to_i, 2
  end

  test "reschedule is reversible — a second call brings the work back" do
    job = build_job
    QueuedJobMaintenance.reschedule!(job_class: "CanaryJob", expected_count: 1, scheduled_at: 6.days.from_now, actor: "test")

    QueuedJobMaintenance.reschedule!(job_class: "CanaryJob", expected_count: 1, scheduled_at: nil, actor: "test")

    assert_in_delta Time.current.to_i, job.reload.scheduled_at.to_i, 5
  end

  test "a reschedule beyond the cap is clamped rather than rejected" do
    freeze_time do
      build_job

      result = QueuedJobMaintenance.reschedule!(
        job_class: "CanaryJob", expected_count: 1, scheduled_at: 60.days.from_now, actor: "test"
      )

      assert_equal Time.current + QueuedJobMaintenance::MAX_RESCHEDULE_DELAY, result.scheduled_at
    end
  end

  test "a reschedule into the past becomes now" do
    freeze_time do
      build_job

      result = QueuedJobMaintenance.reschedule!(
        job_class: "CanaryJob", expected_count: 1, scheduled_at: 3.days.ago, actor: "test"
      )

      assert_equal Time.current, result.scheduled_at
    end
  end

  # The count confirmation promises the caller acts on the set it agreed to. Rows
  # keep arriving while a call runs, so the write has to be bounded by the
  # confirmed count and not by the cap — otherwise a row that landed a
  # millisecond after the count would be discarded without ever having been
  # confirmed.
  test "a row that arrives after the count is not swept up by the same call" do
    2.times { build_job }

    # Fires between the count and the id re-read, which is exactly the window.
    QueuedJobMaintenance.stubs(:preview).returns(
      QueuedJobMaintenance::Preview.new(
        job_class: "CanaryJob", queue_name: nil, matched: 2,
        by_job_class: { "CanaryJob" => 2 }, by_queue: { "default" => 2 }, over_cap: false
      )
    )
    latecomer = build_job(created_at: 1.minute.from_now)

    result = QueuedJobMaintenance.discard!(job_class: "CanaryJob", expected_count: 2, actor: "test")

    assert_equal 2, result.affected
    assert_equal 2, GoodJob::Job.where.not(finished_at: nil).count
    # And it is the LATECOMER that survives, not an arbitrary one of the three:
    # the re-read is ordered oldest-first.
    assert_equal [ latecomer.id ], GoodJob::Job.where(finished_at: nil).pluck(:id)
  end

  test "a count written with a leading zero is read as decimal, not octal" do
    8.times { build_job }

    # "010" is EIGHT to Ruby's default Integer(), and eight rows match — so a
    # confirmation that silently meant something other than it said would go
    # through here rather than being refused.
    error = assert_raises(QueuedJobMaintenance::Refused) do
      QueuedJobMaintenance.discard!(job_class: "CanaryJob", expected_count: "010", actor: "test")
    end

    assert_match(/you expected 10 rows, 8 match/, error.message)
    assert_equal 0, GoodJob::Job.where.not(finished_at: nil).count
  end

  test "a long reason is truncated before it is written onto every row" do
    build_job

    QueuedJobMaintenance.discard!(
      job_class: "CanaryJob", expected_count: 1, reason: "x" * 5_000, actor: "test"
    )

    assert_operator GoodJob::Job.first.error.length, :<,
      QueuedJobMaintenance::MAX_REASON_LENGTH + 200
  end

  # The receipt goes into an agent's context. A call that skips most of a
  # MAX_PER_CALL batch must not serialize thousands of hashes into it.
  test "the skipped list is bounded, and the full count is still reported" do
    (QueuedJobMaintenance::SKIPPED_LIMIT + 5).times { build_job }
    total = QueuedJobMaintenance::SKIPPED_LIMIT + 5
    GoodJob::Job.any_instance.stubs(:discard_job).raises(GoodJob::Job::ActionForStateMismatchError)

    result = QueuedJobMaintenance.discard!(job_class: "CanaryJob", expected_count: total, actor: "test")

    assert_equal 0, result.affected
    assert_equal total, result.skipped_total
    assert_equal QueuedJobMaintenance::SKIPPED_LIMIT, result.skipped.size
    assert_equal QueuedJobMaintenance::SKIPPED_LIMIT, result.as_json[:skipped].size
  end

  # The id re-read is re-filtered through `eligible` rather than replayed as bare
  # ids, so a row that stops being eligible between the read and the write is not
  # touched at all — rather than relying on GoodJob's own guards, which check only
  # `finished_at`, and on an advisory lock strategy a config flag can change.
  test "a row claimed between the id read and the write is not touched" do
    claimed_later = build_job
    build_job

    QueuedJobMaintenance.stubs(:preview).returns(
      QueuedJobMaintenance::Preview.new(
        job_class: "CanaryJob", queue_name: nil, matched: 2,
        by_job_class: { "CanaryJob" => 2 }, by_queue: { "default" => 2 }, over_cap: false
      )
    )
    # Claimed after the count, and after the ids were read: the re-filter is the
    # only thing between it and a discard.
    claimed_later.update_column(:locked_by_id, SecureRandom.uuid)

    result = QueuedJobMaintenance.discard!(job_class: "CanaryJob", expected_count: 2, actor: "test")

    assert_equal 1, result.affected
    assert_nil claimed_later.reload.finished_at
  end

  # === Preview ===

  test "preview counts without touching anything" do
    2.times { build_job(queue_name: "pollers") }
    build_job(queue_name: "default")

    preview = QueuedJobMaintenance.preview(job_class: "CanaryJob")

    assert_equal 3, preview.matched
    assert_equal({ "CanaryJob" => 3 }, preview.by_job_class)
    assert_equal({ "pollers" => 2, "default" => 1 }, preview.by_queue)
    refute preview.over_cap?
    assert_equal 0, GoodJob::Job.where.not(finished_at: nil).count
  end

  test "preview refuses an unscoped read on the surfaces that ask it to" do
    assert_raises(QueuedJobMaintenance::Refused) { QueuedJobMaintenance.preview }
  end

  test "preview allows an unscoped read for the dashboard, which is a read of everything" do
    build_job

    assert_equal 1, QueuedJobMaintenance.preview(require_scope: false).matched
  end

  test "breakdown pairs each class with its queue, biggest first" do
    3.times { build_job(job_class: "CanaryJob", queue_name: "pollers") }
    build_job(job_class: "CanaryJob", queue_name: "default")
    build_job(job_class: "AgentSessionJob", queue_name: "agents")

    rows = QueuedJobMaintenance.breakdown

    assert_equal [
      { job_class: "CanaryJob", queue_name: "pollers", count: 3 },
      { job_class: "CanaryJob", queue_name: "default", count: 1 }
    ], rows
  end

  # === Auditability ===

  test "a discard pages, naming the count and the classes" do
    reports = capture_error_reports do
      2.times { build_job }
      QueuedJobMaintenance.discard!(job_class: "CanaryJob", expected_count: 2, actor: "test")
    end

    report = reports.find { |r| r.message.include?("discarded") }
    assert report, "a bulk discard has to reach somebody who was not reading the transcript"
    assert_equal :error, report.level, "the ERROR record is the half that reaches #alerts"
    assert_includes report.context[:details], "CanaryJob=2"
    assert_includes report.context[:details], "not recoverable"
  end

  test "a refusal pages nobody — nothing happened" do
    reports = capture_error_reports do
      build_job
      assert_raises(QueuedJobMaintenance::Refused) do
        QueuedJobMaintenance.discard!(job_class: "CanaryJob", expected_count: 99, actor: "test")
      end
    end

    assert_empty reports
  end

  test "a failing page does not turn a completed discard into an error" do
    ErrorReporter.stubs(:report_message).raises(StandardError, "glitchtip down")

    build_job
    result = QueuedJobMaintenance.discard!(job_class: "CanaryJob", expected_count: 1, actor: "test")

    assert_equal 1, result.affected
  end

  # A row that changes state between the count and the write is reported rather
  # than swallowed, and does not abandon the rest of the batch.
  test "a row that refuses mid-call is skipped and reported, and the rest still get done" do
    2.times { build_job }
    GoodJob::Job.any_instance.stubs(:discard_job)
      .raises(GoodJob::Job::ActionForStateMismatchError)
      .then.returns(true)

    result = QueuedJobMaintenance.discard!(job_class: "CanaryJob", expected_count: 2, actor: "test")

    assert_equal 1, result.affected
    assert_equal 1, result.skipped.size
    assert_match(/ActionForStateMismatchError/, result.skipped.first[:reason])
  end
end
