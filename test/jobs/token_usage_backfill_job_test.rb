# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"
require "tmpdir"

class TokenUsageBackfillJobTest < ActiveJob::TestCase
  def setup
    @root = Dir.mktmpdir("token_usage_backfill_job_test_")
    TokenUsageIngestionService.stubs(:default_root).returns(@root)
  end

  def teardown
    FileUtils.rm_rf(@root)
  end

  test "starts and works a run on the first tick when history has never been swept" do
    assert_difference -> { TokenUsageBackfill.count }, 1 do
      TokenUsageBackfillJob.perform_now
    end

    run = TokenUsageBackfill.latest
    assert_equal "automatic", run.trigger
    assert_equal @root, run.transcript_root
    assert run.complete?, "an empty corpus is covered in one slice"
  end

  test "does nothing at all once a sweep has completed — every deploy after the first" do
    TokenUsageBackfillJob.perform_now
    assert TokenUsageBackfill.ever_completed?

    assert_no_difference -> { TokenUsageBackfill.count } do
      assert_nil TokenUsageBackfillJob.perform_now, "a completed backfill leaves nothing to do"
    end
  end

  test "picks up a run somebody asked for even though history is already swept" do
    TokenUsageBackfillJob.perform_now
    requested = TokenUsageBackfill.request!(trigger: "manual")

    TokenUsageBackfillJob.perform_now

    assert requested.reload.complete?
    assert_equal 2, TokenUsageBackfill.count
  end

  test "resumes the unfinished run instead of starting another" do
    stalled = TokenUsageBackfill.create!(transcript_root: @root, started_at: 1.hour.ago)

    assert_no_difference -> { TokenUsageBackfill.count } do
      TokenUsageBackfillJob.perform_now
    end

    assert stalled.reload.complete?
  end

  test "runs on the default queue, not pollers" do
    # Bulk work that holds its thread for minutes must not sit on the queue the
    # latency-sensitive singleton pollers share.
    assert_equal "default", TokenUsageBackfillJob.new.queue_name
  end
end
