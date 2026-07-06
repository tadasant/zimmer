# frozen_string_literal: true

require "test_helper"

class CliStatusRefreshJobTest < ActiveJob::TestCase
  setup do
    # Use memory store for cache tests (test env uses null_store by default)
    @original_cache = Rails.cache
    @test_cache = ActiveSupport::Cache::MemoryStore.new
    Rails.cache = @test_cache
  end

  teardown do
    # Restore original cache
    Rails.cache = @original_cache
  end

  test "performs without error" do
    assert_nothing_raised do
      CliStatusRefreshJob.perform_now
    end
  end

  test "caches the CLI status report" do
    # Ensure cache is empty before test
    assert_nil Rails.cache.read(CliStatusService::CACHE_KEY)

    # Perform the job
    CliStatusRefreshJob.perform_now

    # Verify cache was populated
    cached_report = Rails.cache.read(CliStatusService::CACHE_KEY)
    assert_not_nil cached_report
    assert cached_report.key?(:tools)
    assert cached_report.key?(:unauthenticated_count)
    assert cached_report.key?(:generated_at)
  end

  test "cached report contains all CLI tools" do
    CliStatusRefreshJob.perform_now

    cached_report = Rails.cache.read(CliStatusService::CACHE_KEY)
    tools = cached_report[:tools]

    assert tools.key?(:gh), "Expected :gh tool in cached report"
    assert tools.key?(:claude), "Expected :claude tool in cached report"
    assert tools.key?(:fly), "Expected :fly tool in cached report"
  end

  test "each tool has required status fields" do
    CliStatusRefreshJob.perform_now

    cached_report = Rails.cache.read(CliStatusService::CACHE_KEY)
    cached_report[:tools].each do |tool_name, tool_status|
      assert tool_status.key?(:name), "Tool #{tool_name} should have :name"
      assert tool_status.key?(:installed), "Tool #{tool_name} should have :installed"
      assert tool_status.key?(:authenticated), "Tool #{tool_name} should have :authenticated"
      assert tool_status.key?(:auth_method), "Tool #{tool_name} should have :auth_method"
    end
  end

  test "can be enqueued" do
    assert_enqueued_with(job: CliStatusRefreshJob) do
      CliStatusRefreshJob.perform_later
    end
  end

  test "uses pollers queue" do
    job = CliStatusRefreshJob.new
    assert_equal "pollers", job.queue_name
  end
end
