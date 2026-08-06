# frozen_string_literal: true

require "test_helper"

class JobLivenessTest < ActiveSupport::TestCase
  ALL_STATUSES = %i[running queued scheduled finished dead_worker interrupted abandoned].freeze

  def setup
    GoodJob::Process.delete_all
    GoodJob::Job.delete_all
  end

  def teardown
    GoodJob::Process.delete_all
    GoodJob::Job.delete_all
  end

  # A GoodJob capsule that is alive: registered and refreshing its heartbeat.
  def live_process
    GoodJob::Process.create!(state: { "hostname" => "worker-1" })
  end

  # A capsule that was SIGKILLed. Its row survives — nothing deletes it until some
  # later capsule boots and runs GoodJob::Process.cleanup — but the heartbeat stopped.
  def dead_process(seconds_since_heartbeat: GoodJob::Process::EXPIRED_INTERVAL.to_i + 60)
    process = GoodJob::Process.create!(state: { "hostname" => "worker-1" })
    process.update_column(:updated_at, seconds_since_heartbeat.seconds.ago)
    process
  end

  def good_job(**attrs)
    GoodJob::Job.create!({
      queue_name: "agents",
      job_class: "AgentSessionJob",
      active_job_id: SecureRandom.uuid,
      serialized_params: { arguments: [ 1 ] }.to_json
    }.merge(attrs))
  end

  # --- lock holder liveness --------------------------------------------------

  test "lock_holder_alive? is true for a capsule that is refreshing its heartbeat" do
    assert JobLiveness.lock_holder_alive?(live_process.id)
  end

  test "lock_holder_alive? is false for a capsule whose heartbeat expired" do
    process = dead_process

    # The distinction the whole check turns on: the row still EXISTS. Existence is not
    # liveness — nothing deletes the row when the worker dies.
    assert GoodJob::Process.exists?(id: process.id)
    assert_not JobLiveness.lock_holder_alive?(process.id)
  end

  test "lock_holder_alive? is true for a capsule holding an advisory lock even without a fresh heartbeat" do
    process = GoodJob::Process.create!(state: { "hostname" => "worker-1" })
    process.update!(lock_type: :advisory)
    process.update_column(:updated_at, 1.hour.ago)
    process.advisory_lock!

    begin
      assert JobLiveness.lock_holder_alive?(process.id),
        "a lock held on a live connection is proof of life regardless of heartbeat age"
    ensure
      process.advisory_unlock
    end
  end

  test "lock_holder_alive? is false once the advisory lock is released" do
    # Postgres releases a session-scoped advisory lock the moment the connection holding
    # it goes away, which is what makes this signal work across containers and hosts:
    # nobody has to report the death, and no PID is involved.
    process = GoodJob::Process.create!(state: { "hostname" => "worker-1" })
    process.update!(lock_type: :advisory)

    assert_not JobLiveness.lock_holder_alive?(process.id),
      "a capsule registered with lock_type=advisory that holds no lock is gone: its connection died"
  end

  test "lock_holder_alive? is false for a process id with no row at all" do
    assert_not JobLiveness.lock_holder_alive?(SecureRandom.uuid)
  end

  test "lock_holder_alive? is false for a blank process id" do
    assert_not JobLiveness.lock_holder_alive?(nil)
    assert_not JobLiveness.lock_holder_alive?("")
  end

  # --- status classification -------------------------------------------------

  test "a job locked by a live capsule is running" do
    job = good_job(locked_by_id: live_process.id, locked_at: 1.minute.ago, performed_at: 1.minute.ago)

    assert_equal :running, JobLiveness.status(job)
    assert JobLiveness.alive?(job)
    assert_not_includes JobLiveness::SUPERSEDABLE_STATUSES, JobLiveness.status(job)
  end

  test "a job whose lock holder is gone is a dead worker, however recently it was enqueued" do
    job = good_job(
      created_at: 5.seconds.ago,
      locked_by_id: dead_process.id,
      locked_at: 5.seconds.ago,
      performed_at: 5.seconds.ago
    )

    assert_equal :dead_worker, JobLiveness.status(job)
    assert_includes JobLiveness::SUPERSEDABLE_STATUSES, JobLiveness.status(job)
  end

  test "a job that started and then lost its lock is interrupted" do
    # GoodJob::Process.cleanup nulls locked_by_id on behalf of a capsule that died
    # mid-perform. performed_at is what distinguishes this from a job never picked up.
    job = good_job(created_at: 20.seconds.ago, performed_at: 15.seconds.ago, locked_by_id: nil)

    assert_equal :interrupted, JobLiveness.status(job)
    assert_includes JobLiveness::SUPERSEDABLE_STATUSES, JobLiveness.status(job)
  end

  test "a queued job is alive no matter how long the queue is" do
    # A slow deploy or a busy worker means a job waits, not that it died. GoodJob will
    # still run it, so superseding here starts a second agent on the same clone.
    job = good_job(created_at: 20.minutes.ago, scheduled_at: 20.minutes.ago)

    assert_equal :queued, JobLiveness.status(job)
    assert JobLiveness.alive?(job)
    assert_not_includes JobLiveness::SUPERSEDABLE_STATUSES, JobLiveness.status(job)
  end

  test "a job parked on a future retry backoff is scheduled, not stale" do
    # AgentSessionJob's transient-clone retry points running_job_id at a job scheduled up
    # to 10 minutes out. Superseding it would double-run the session against the pending retry.
    job = good_job(created_at: 5.minutes.ago, scheduled_at: 10.minutes.from_now)

    assert_equal :scheduled, JobLiveness.status(job)
    assert_not_includes JobLiveness::SUPERSEDABLE_STATUSES, JobLiveness.status(job)
  end

  test "a job queued past the backstop horizon is abandoned" do
    job = good_job(
      created_at: JobLiveness::ABANDONED_QUEUED_JOB_AGE.ago - 1.minute,
      scheduled_at: JobLiveness::ABANDONED_QUEUED_JOB_AGE.ago - 1.minute
    )

    assert_equal :abandoned, JobLiveness.status(job)
    assert_includes JobLiveness::SUPERSEDABLE_STATUSES, JobLiveness.status(job)
  end

  test "the backstop does not fire one minute before its horizon" do
    job = good_job(
      created_at: JobLiveness::ABANDONED_QUEUED_JOB_AGE.ago + 1.minute,
      scheduled_at: JobLiveness::ABANDONED_QUEUED_JOB_AGE.ago + 1.minute
    )

    assert_equal :queued, JobLiveness.status(job)
  end

  test "the backstop is a backstop: far longer than the queue delay it replaces" do
    assert_operator JobLiveness::ABANDONED_QUEUED_JOB_AGE, :>, 10.minutes,
      "the fallback must stay far clear of real queue delays, or it becomes the primary mechanism"
  end

  test "a finished job is not alive, and is safe to supersede" do
    # Not a live status, so it must fall on the supersede side. A caller that branched only
    # on LIVE_STATUSES and let this drop through to "wait" would strand a session behind a
    # job that already completed.
    job = good_job(finished_at: 1.minute.ago, performed_at: 5.minutes.ago)

    assert_equal :finished, JobLiveness.status(job)
    assert_not JobLiveness.alive?(job)
    assert_includes JobLiveness::SUPERSEDABLE_STATUSES, JobLiveness.status(job)
  end

  test "a missing job row is finished" do
    assert_equal :finished, JobLiveness.status(nil)
  end

  test "explain returns a sentence for every status" do
    ALL_STATUSES.each do |status|
      assert_match(/\w/, JobLiveness.explain(status))
      assert_not_includes JobLiveness.explain(status), "status #{status}",
        "#{status} should have a written explanation, not the fallback"
    end
  end

  # --- the sets are a partition ----------------------------------------------

  test "LIVE_STATUSES and SUPERSEDABLE_STATUSES partition every status" do
    # A caller branching on one set must handle every case, or a status added later falls
    # through to whichever branch happens to be the `else` — silently, and in the direction
    # that drops a prompt. Disjoint and exhaustive is the invariant that makes the branch safe.
    overlap = JobLiveness::LIVE_STATUSES & JobLiveness::SUPERSEDABLE_STATUSES
    assert_empty overlap, "a status cannot be both live and supersedable"
    assert_equal ALL_STATUSES.sort,
      (JobLiveness::LIVE_STATUSES + JobLiveness::SUPERSEDABLE_STATUSES).sort
  end

  test "every status the classifier can return is covered by the two sets" do
    # Enumerated from real rows rather than from the constants, so a new branch in .status
    # that nobody added to a set fails here.
    covered = JobLiveness::LIVE_STATUSES + JobLiveness::SUPERSEDABLE_STATUSES

    observed = [
      JobLiveness.status(nil),
      JobLiveness.status(good_job(finished_at: 1.minute.ago)),
      JobLiveness.status(good_job(locked_by_id: live_process.id, locked_at: 1.minute.ago)),
      JobLiveness.status(good_job(locked_by_id: dead_process.id, locked_at: 1.minute.ago)),
      JobLiveness.status(good_job(scheduled_at: 10.minutes.from_now)),
      JobLiveness.status(good_job(performed_at: 1.minute.ago)),
      JobLiveness.status(good_job(created_at: 1.minute.ago, scheduled_at: 1.minute.ago)),
      JobLiveness.status(good_job(
        created_at: JobLiveness::ABANDONED_QUEUED_JOB_AGE.ago - 1.minute,
        scheduled_at: JobLiveness::ABANDONED_QUEUED_JOB_AGE.ago - 1.minute
      ))
    ]

    assert_equal ALL_STATUSES.sort, observed.uniq.sort,
      "the classifier should be able to produce exactly the enumerated statuses"
    observed.each { |status| assert_includes covered, status }
  end
end
