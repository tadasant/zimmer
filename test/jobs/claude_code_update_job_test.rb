# frozen_string_literal: true

require "test_helper"

class ClaudeCodeUpdateJobTest < ActiveJob::TestCase
  test "can be enqueued" do
    assert_enqueued_with(job: ClaudeCodeUpdateJob) do
      ClaudeCodeUpdateJob.perform_later
    end
  end

  test "uses the blocking maintenance queue" do
    job = ClaudeCodeUpdateJob.new
    assert_equal "maintenance", job.queue_name
  end

  test "performs without error" do
    assert_nothing_raised do
      ClaudeCodeUpdateJob.perform_now
    end
  end

  test "enqueues CliStatusRefreshJob after performing" do
    assert_enqueued_with(job: CliStatusRefreshJob) do
      ClaudeCodeUpdateJob.perform_now
    end
  end

  test "defines UPDATE_TIMEOUT constant" do
    assert_equal 120, ClaudeCodeUpdateJob::UPDATE_TIMEOUT
  end
end
