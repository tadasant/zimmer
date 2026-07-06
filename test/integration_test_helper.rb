# frozen_string_literal: true

require "test_helper"

# Base class for integration tests
# Tests multi-component workflows without browser automation
class IntegrationTestCase < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  # Don't use transactional fixtures for integration tests to avoid locks
  self.use_transactional_tests = false

  setup do
    # Clean database before each test
    DatabaseCleaner.start
    setup_test_session
  end

  teardown do
    # Clean up after test
    DatabaseCleaner.clean
    cleanup_test_session
  end

  private

  def setup_test_session
    @test_session = nil
  end

  def cleanup_test_session
    @test_session&.destroy
  end

  # Helper to create a session and enqueue job without executing
  def create_session_with_job(params = {})
    default_params = {
      prompt: "Test prompt",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      status: "waiting"
    }

    session = Session.create!(default_params.merge(params))

    # Enqueue but don't perform the job
    assert_enqueued_with(job: AgentSessionJob, args: [ session.id ]) do
      AgentSessionJob.enqueue_new_session(session.id)
    end

    session
  end

  # Helper to simulate job completion
  def simulate_job_completion(session, status: "archived")
    session.update!(
      status: status,
      running_job_id: nil,
      transcript: '{"messages": ["Job completed"]}',
      last_timeline_entry_at: Time.current
    )

    Log.create!(
      session: session,
      level: "info",
      content: "Job completed with status: #{status}"
    )
  end

  # Helper to simulate job failure
  def simulate_job_failure(session, error: "Simulated error")
    session.update!(
      status: "failed",
      running_job_id: nil
    )

    Log.create!(
      session: session,
      level: "error",
      content: error
    )
  end

  # Helper to create follow-up prompt
  def create_follow_up(session, prompt)
    session.update!(
      status: "waiting",
      follow_up_prompt: prompt
    )

    assert_enqueued_with(job: AgentSessionJob, args: [ session.id, prompt ]) do
      AgentSessionJob.enqueue_with_prompt(session.id, prompt)
    end
  end

  # Database cleaner for non-transactional tests
  module DatabaseCleaner
    # Store IDs that existed before the test started (fixtures)
    @fixture_session_ids = []
    @fixture_log_ids = []
    @fixture_enqueued_message_ids = []
    @fixture_notification_ids = []

    def self.start
      # Store fixture IDs so we don't delete them during cleanup
      @fixture_session_ids = Session.pluck(:id)
      @fixture_log_ids = Log.pluck(:id)
      @fixture_enqueued_message_ids = EnqueuedMessage.pluck(:id)
      @fixture_notification_ids = Notification.pluck(:id)
    end

    def self.clean
      # Clean only records created during the test, not fixtures
      # Delete in order: child records first, then sessions (respecting FK constraints)
      Log.where.not(id: @fixture_log_ids).delete_all
      EnqueuedMessage.where.not(id: @fixture_enqueued_message_ids).delete_all
      Notification.where.not(id: @fixture_notification_ids).delete_all
      Session.where.not(id: @fixture_session_ids).delete_all
      GoodJob::Job.delete_all if defined?(GoodJob::Job)
    end
  end
end
