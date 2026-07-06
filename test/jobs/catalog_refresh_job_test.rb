# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class CatalogRefreshJobTest < ActiveSupport::TestCase
  test "job is enqueued in pollers queue" do
    assert_equal "pollers", CatalogRefreshJob.new.queue_name
  end

  test "job has concurrency control" do
    # CatalogRefreshJob should have a total_limit of 1 to prevent
    # duplicate concurrent runs
    assert CatalogRefreshJob.good_job_concurrency_config.present?
  end

  test "perform delegates to AirCatalogService.refresh!" do
    AirCatalogService.expects(:refresh!).once.returns(true)

    CatalogRefreshJob.new.perform
  end

  test "perform re-raises CatalogError after logging so the job record reflects failure" do
    AirCatalogService.expects(:refresh!).once
      .raises(AirCatalogService::CatalogError, "git fetch failed")
    Rails.logger.expects(:error).with(regexp_matches(/Catalog refresh failed: git fetch failed/))

    error = assert_raises(AirCatalogService::CatalogError) do
      CatalogRefreshJob.new.perform
    end
    assert_match(/git fetch failed/, error.message)
  end

  # --- perform_and_wait -----------------------------------------------------

  # Stand-in for a GoodJob::Job record with just the fields perform_and_wait reads.
  FakeJobRecord = Struct.new(:finished_at, :error, keyword_init: true)

  # Monotonic clock that advances a fixed step per read, so the deadline is hit
  # deterministically without real time passing.
  class FakeClock
    def initialize(step: 1)
      @now = 0
      @step = step
    end

    def clock_gettime(_clock_id)
      value = @now
      @now += @step
      value
    end
  end

  test "perform_and_wait returns :ok when the job finishes without error" do
    CatalogRefreshJob.stubs(:enqueue_or_find_inflight).returns("job-123")
    GoodJob::Job.stubs(:find_by).with(id: "job-123")
      .returns(FakeJobRecord.new(finished_at: Time.current, error: nil))

    result = CatalogRefreshJob.perform_and_wait(timeout: 10, poll_interval: 0, sleeper: ->(_) { })

    assert result.ok?
    assert_nil result.error_message
  end

  test "perform_and_wait returns :failed with the recorded error message" do
    CatalogRefreshJob.stubs(:enqueue_or_find_inflight).returns("job-123")
    GoodJob::Job.stubs(:find_by).with(id: "job-123")
      .returns(FakeJobRecord.new(finished_at: Time.current, error: "CatalogError: boom"))

    result = CatalogRefreshJob.perform_and_wait(timeout: 10, poll_interval: 0, sleeper: ->(_) { })

    assert result.failed?
    assert_equal "CatalogError: boom", result.error_message
  end

  test "perform_and_wait returns :timeout when the job never finishes" do
    CatalogRefreshJob.stubs(:enqueue_or_find_inflight).returns("job-123")
    GoodJob::Job.stubs(:find_by).with(id: "job-123")
      .returns(FakeJobRecord.new(finished_at: nil, error: nil))

    result = CatalogRefreshJob.perform_and_wait(
      timeout: 2, poll_interval: 0, clock: FakeClock.new(step: 1), sleeper: ->(_) { }
    )

    assert result.timed_out?
  end

  test "perform_and_wait returns :ok when the finished record was already reaped" do
    CatalogRefreshJob.stubs(:enqueue_or_find_inflight).returns("job-123")
    GoodJob::Job.stubs(:find_by).with(id: "job-123").returns(nil)

    result = CatalogRefreshJob.perform_and_wait(timeout: 10, poll_interval: 0, sleeper: ->(_) { })

    assert result.ok?
  end

  test "perform_and_wait polls with the query cache disabled" do
    # Regression guard: perform_and_wait runs inside a web request where the
    # ActiveRecord per-request query cache is active. If the polling find_by is not
    # wrapped in uncached, the first (finished_at: nil) snapshot is cached and every
    # later poll returns that stale row, so the loop never sees the job finish and
    # always times out. Assert the loop is wrapped in GoodJob::Job.uncached.
    CatalogRefreshJob.stubs(:enqueue_or_find_inflight).returns("job-123")
    GoodJob::Job.stubs(:find_by).with(id: "job-123")
      .returns(FakeJobRecord.new(finished_at: Time.current, error: nil))
    GoodJob::Job.expects(:uncached).once.yields

    result = CatalogRefreshJob.perform_and_wait(timeout: 10, poll_interval: 0, sleeper: ->(_) { })

    assert result.ok?
  end

  test "perform_and_wait returns :timeout when nothing is available to wait on" do
    CatalogRefreshJob.stubs(:enqueue_or_find_inflight).returns(nil)

    result = CatalogRefreshJob.perform_and_wait(timeout: 10, poll_interval: 0, sleeper: ->(_) { })

    assert result.timed_out?
  end

  test "enqueue_or_find_inflight returns the provider job id of a fresh enqueue" do
    enqueued = mock("active_job")
    enqueued.stubs(:respond_to?).with(:successfully_enqueued?).returns(true)
    enqueued.stubs(:successfully_enqueued?).returns(true)
    enqueued.stubs(:provider_job_id).returns("fresh-id")
    CatalogRefreshJob.stubs(:perform_later).returns(enqueued)

    assert_equal "fresh-id", CatalogRefreshJob.enqueue_or_find_inflight
  end

  test "enqueue_or_find_inflight latches onto an in-flight run when enqueue is rejected" do
    rejected = mock("active_job")
    rejected.stubs(:respond_to?).with(:successfully_enqueued?).returns(true)
    rejected.stubs(:successfully_enqueued?).returns(false)
    CatalogRefreshJob.stubs(:perform_later).returns(rejected)

    relation = mock("relation")
    GoodJob::Job.stubs(:where)
      .with(concurrency_key: CatalogRefreshJob::CONCURRENCY_KEY, finished_at: nil)
      .returns(relation)
    relation.stubs(:order).with(created_at: :asc).returns(relation)
    relation.stubs(:pick).with(:id).returns("inflight-id")

    assert_equal "inflight-id", CatalogRefreshJob.enqueue_or_find_inflight
  end
end
