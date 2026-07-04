# frozen_string_literal: true

# Helpers for testing Turbo Stream broadcasts in tests.
# Provides utilities to assert that broadcasts were sent with expected content.
#
# Note: These helpers work by counting broadcasts during a block execution.
# They are useful for integration tests that need to verify broadcast behavior.
#
# Usage:
#   test "broadcasts on update" do
#     session = create_session
#     assert_broadcasts(session, 1) do
#       session.update!(status: :running)
#     end
#   end
module BroadcastHelpers
  # Assert that a specific number of broadcasts were sent to a streamable
  # @param streamable [Object] The object to check broadcasts for (e.g., Session, Log)
  # @param count [Integer] Expected number of broadcasts (default: 1)
  # @yield Block to execute while counting broadcasts
  #
  # Example:
  #   assert_broadcasts(@session, 2) do
  #     @session.update!(status: :running)
  #     @session.update!(status: :failed)
  #   end
  def assert_broadcasts(streamable, count = 1)
    # Count broadcasts by checking the number of jobs enqueued
    # Turbo broadcasts use ActionCable which enqueues broadcast jobs
    initial_job_count = count_broadcast_jobs_for(streamable)

    yield

    final_job_count = count_broadcast_jobs_for(streamable)
    actual_count = final_job_count - initial_job_count

    assert_equal count, actual_count,
                 "Expected #{count} broadcast(s), got #{actual_count}"
  end

  # Assert that no broadcasts were sent to a streamable
  # @param streamable [Object] The object to check broadcasts for
  # @yield Block to execute while verifying no broadcasts
  #
  # Example:
  #   assert_no_broadcasts(@session) do
  #     @session.reload # Should not trigger broadcast
  #   end
  def assert_no_broadcasts(streamable)
    assert_broadcasts(streamable, 0) { yield }
  end

  # Assert that at least one broadcast was sent
  # Useful when you don't care about the exact count
  # @param streamable [Object] The object to check broadcasts for
  # @yield Block to execute while checking for broadcasts
  #
  # Example:
  #   assert_broadcast_sent(@session) do
  #     @session.update!(status: :running)
  #   end
  def assert_broadcast_sent(streamable)
    initial_job_count = count_broadcast_jobs_for(streamable)

    yield

    final_job_count = count_broadcast_jobs_for(streamable)
    actual_count = final_job_count - initial_job_count

    assert actual_count > 0, "Expected at least one broadcast, but none were sent"
  end

  private

  # Count broadcast jobs for a given streamable
  # This is a simplified implementation that counts all broadcast jobs
  # In a real implementation, you might want to filter by stream name
  def count_broadcast_jobs_for(_streamable)
    # In test mode, Turbo broadcasts are typically handled via test adapter
    # This is a simplified counter - for more precise counting,
    # you would need to track the specific stream names
    enqueued_jobs = ActiveJob::Base.queue_adapter.enqueued_jobs
    enqueued_jobs.count { |job| job[:job].to_s.include?("Broadcast") || job[:job].to_s.include?("Turbo") }
  end
end
