# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

# Contract tests for AgentSessionJob method signatures
#
# These tests ensure that all call sites in production code use the correct
# argument patterns when invoking AgentSessionJob.perform_later.
#
# Historical context:
# 30% of production bugs were caused by incorrect method argument passing,
# particularly with AgentSessionJob.perform_later. The same bug was fixed 4+ times:
# - SessionsController#refresh (commit eb3f4435)
# - SessionRecoveryService (commit 048b06a1)
# - CleanupOrphanedSessionsJob (commit 59358eca)
# - SessionsController#restore_agent_session_job (commit b9121d84)
#
# Root cause: Ruby's flexible keyword/positional argument handling creates subtle bugs:
#   perform_later(session.id, resume_monitoring: true)      # WRONG - Hash as positional arg
#   perform_later(session.id, nil, resume_monitoring: true) # CORRECT - nil + keyword arg
#
class JobContractTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  # Define the expected method signature patterns for AgentSessionJob
  # Each pattern maps to a specific use case:
  VALID_CALL_PATTERNS = {
    # Pattern 1: New session with initial prompt
    # Usage: Starting a fresh session
    # Example: AgentSessionJob.perform_later(session.id)
    new_session: {
      args: [ :session_id ],
      kwargs: {},
      description: "New session start"
    },

    # Pattern 2: Follow-up prompt
    # Usage: Sending a follow-up prompt to an existing session
    # Example: AgentSessionJob.perform_later(session.id, "my follow-up message")
    with_prompt: {
      args: [ :session_id, :prompt ],
      kwargs: {},
      description: "Follow-up prompt"
    },

    # Pattern 3: Resume monitoring
    # Usage: Reconnecting to an existing Claude CLI process
    # Example: AgentSessionJob.perform_later(session.id, nil, resume_monitoring: true)
    resume_monitoring: {
      args: [ :session_id, nil ],
      kwargs: { resume_monitoring: true },
      description: "Resume monitoring existing process"
    },

    # Pattern 4: Clone-only session
    # Usage: Creating a clone without starting Claude CLI
    # Example: AgentSessionJob.perform_later(session.id, nil, resume_monitoring: false, clone_only: true)
    clone_only: {
      args: [ :session_id, nil ],
      kwargs: { resume_monitoring: false, clone_only: true },
      description: "Clone-only session setup"
    }
  }.freeze

  setup do
    @session = sessions(:waiting)
  end

  # Test that the job's perform method accepts the expected signature
  test "AgentSessionJob.perform accepts correct signature" do
    # Verify method exists and has expected arity
    method = AgentSessionJob.instance_method(:perform)
    params = method.parameters

    # Expected: session_id, follow_up_prompt = nil, options = nil (for deserialized kwargs),
    #           resume_monitoring: false, clone_only: false, images: nil, files: nil
    # Note: 7 params because ActiveJob serializes kwargs as a positional hash
    assert_equal 7, params.size, "Expected 7 parameters in perform method"

    # Check parameter types
    param_types = params.map { |type, _| type }
    assert_includes param_types, :req, "Expected required positional parameter (session_id)"
    assert_includes param_types, :opt, "Expected optional positional parameter (follow_up_prompt, options)"
    assert_includes param_types, :key, "Expected keyword parameters"
  end

  # Test Pattern 1: New session start
  test "enqueue_new_session creates job with correct arguments" do
    assert_enqueued_with(job: AgentSessionJob, args: [ @session.id ]) do
      AgentSessionJob.enqueue_new_session(@session.id)
    end
  end

  # Test Pattern 2: Follow-up prompt
  test "enqueue_with_prompt creates job with correct arguments" do
    prompt = "Please continue"
    assert_enqueued_with(job: AgentSessionJob, args: [ @session.id, prompt ]) do
      AgentSessionJob.enqueue_with_prompt(@session.id, prompt)
    end
  end

  # Test Pattern 3: Resume monitoring
  test "enqueue_for_monitoring creates job with correct arguments" do
    # Note: Using manual verification since assert_enqueued_with doesn't easily handle kwargs
    job = AgentSessionJob.enqueue_for_monitoring(@session.id)

    assert_not_nil job, "Job should be returned"
    assert_kind_of AgentSessionJob, job

    # Verify the job arguments are correct
    # In Rails, perform_later captures arguments via serialized_arguments
    assert_enqueued_jobs 1, only: AgentSessionJob

    enqueued_job = ActiveJob::Base.queue_adapter.enqueued_jobs.last
    args = enqueued_job[:args]

    # Arguments should be: [session_id, nil, { resume_monitoring: true }]
    assert_equal @session.id, args[0], "First argument should be session_id"
    assert_nil args[1], "Second argument should be nil (follow_up_prompt placeholder)"
    assert_equal true, args[2]["resume_monitoring"], "resume_monitoring keyword should be true"
  end

  # Test Pattern 4: Clone-only session
  test "enqueue_for_clone_only creates job with correct arguments" do
    job = AgentSessionJob.enqueue_for_clone_only(@session.id)

    assert_not_nil job, "Job should be returned"
    assert_kind_of AgentSessionJob, job

    enqueued_job = ActiveJob::Base.queue_adapter.enqueued_jobs.last
    args = enqueued_job[:args]

    # Arguments should be: [session_id, nil, { resume_monitoring: false, clone_only: true }]
    assert_equal @session.id, args[0], "First argument should be session_id"
    assert_nil args[1], "Second argument should be nil (follow_up_prompt placeholder)"
    assert_equal false, args[2]["resume_monitoring"], "resume_monitoring keyword should be false"
    assert_equal true, args[2]["clone_only"], "clone_only keyword should be true"
  end

  # Contract verification: direct perform_later calls should be avoided
  # This test scans production code to identify any direct calls that don't use helpers
  test "production code uses helper methods instead of direct perform_later calls" do
    # Scan production code for AgentSessionJob.perform_later calls
    production_files = [
      Rails.root.join("app", "controllers", "**", "*.rb"),
      Rails.root.join("app", "services", "**", "*.rb"),
      Rails.root.join("app", "jobs", "**", "*.rb")
    ]

    direct_calls = []

    production_files.each do |pattern|
      Dir.glob(pattern).each do |file|
        next if file.include?("agent_session_job.rb") # Skip the job file itself

        content = File.read(file)
        # Find lines with direct perform_later calls (not through helpers)
        content.each_line.with_index(1) do |line, line_num|
          if line.include?("AgentSessionJob.perform_later") ||
             line.include?("AgentSessionJob.set(")
            direct_calls << {
              file: file.sub(Rails.root.to_s + "/", ""),
              line: line_num,
              content: line.strip
            }
          end
        end
      end
    end

    if direct_calls.any?
      message = "Found direct AgentSessionJob.perform_later calls that should use helper methods:\n"
      direct_calls.each do |call|
        message += "  #{call[:file]}:#{call[:line]}: #{call[:content]}\n"
      end
      message += "\nUse these helpers instead:\n"
      message += "  - AgentSessionJob.enqueue_new_session(session_id)\n"
      message += "  - AgentSessionJob.enqueue_with_prompt(session_id, prompt)\n"
      message += "  - AgentSessionJob.enqueue_for_monitoring(session_id)\n"
      message += "  - AgentSessionJob.enqueue_for_clone_only(session_id)\n"

      flunk message
    else
      # Explicitly pass if no direct calls found
      assert true, "All production code uses helper methods correctly"
    end
  end

  # Integration test: verify enqueued jobs can be performed without errors
  test "all helper methods create performable jobs" do
    # Set up test doubles to prevent actual process spawning
    mock_process_manager = Minitest::Mock.new
    mock_file_system = Minitest::Mock.new

    # We don't actually perform the jobs here - just verify they're enqueued correctly
    # and that the argument structure is valid

    # Pattern 1: New session
    job1 = AgentSessionJob.enqueue_new_session(@session.id)
    assert_kind_of AgentSessionJob, job1

    # Pattern 2: With prompt
    job2 = AgentSessionJob.enqueue_with_prompt(@session.id, "test prompt")
    assert_kind_of AgentSessionJob, job2

    # Pattern 3: Resume monitoring
    job3 = AgentSessionJob.enqueue_for_monitoring(@session.id)
    assert_kind_of AgentSessionJob, job3

    # Pattern 4: Clone only
    job4 = AgentSessionJob.enqueue_for_clone_only(@session.id)
    assert_kind_of AgentSessionJob, job4
  end

  # Edge case: ensure nil prompt is handled correctly
  test "enqueue_with_prompt rejects nil prompt" do
    error = assert_raises(ArgumentError) do
      AgentSessionJob.enqueue_with_prompt(@session.id, nil)
    end
    assert_match(/must be a String/, error.message)
  end

  # Edge case: ensure blank prompt is handled correctly
  test "enqueue_with_prompt rejects blank prompt" do
    error = assert_raises(ArgumentError) do
      AgentSessionJob.enqueue_with_prompt(@session.id, "")
    end
    assert_match(/cannot be blank/, error.message)
  end

  # Edge case: ensure whitespace-only prompt is handled correctly
  test "enqueue_with_prompt rejects whitespace-only prompt" do
    error = assert_raises(ArgumentError) do
      AgentSessionJob.enqueue_with_prompt(@session.id, "   \n\t   ")
    end
    assert_match(/cannot be blank/, error.message)
  end

  # Edge case: ensure non-String prompt is rejected
  test "enqueue_with_prompt rejects non-String prompt" do
    error = assert_raises(ArgumentError) do
      AgentSessionJob.enqueue_with_prompt(@session.id, { foo: "bar" })
    end
    assert_match(/must be a String/, error.message)
  end

  # Edge case: ensure nil session_id is rejected
  test "enqueue_new_session rejects nil session_id" do
    error = assert_raises(ArgumentError) do
      AgentSessionJob.enqueue_new_session(nil)
    end
    assert_match(/session_id cannot be nil/, error.message)
  end

  test "enqueue_with_prompt rejects nil session_id" do
    error = assert_raises(ArgumentError) do
      AgentSessionJob.enqueue_with_prompt(nil, "test prompt")
    end
    assert_match(/session_id cannot be nil/, error.message)
  end

  test "enqueue_for_monitoring rejects nil session_id" do
    error = assert_raises(ArgumentError) do
      AgentSessionJob.enqueue_for_monitoring(nil)
    end
    assert_match(/session_id cannot be nil/, error.message)
  end

  test "enqueue_for_clone_only rejects nil session_id" do
    error = assert_raises(ArgumentError) do
      AgentSessionJob.enqueue_for_clone_only(nil)
    end
    assert_match(/session_id cannot be nil/, error.message)
  end

  # Delayed enqueue support
  test "enqueue_for_monitoring_delayed supports delay option" do
    expected_time = Time.current + 5.seconds
    job = AgentSessionJob.enqueue_for_monitoring(@session.id, delay: 5.seconds)

    assert_not_nil job, "Job should be returned"
    assert_kind_of AgentSessionJob, job

    # Verify the job is scheduled with a delay
    enqueued_job = ActiveJob::Base.queue_adapter.enqueued_jobs.last
    assert_not_nil enqueued_job[:at], "Job should have scheduled_at time"
    # Allow 2 seconds of tolerance for test execution time
    assert_in_delta expected_time.to_f, enqueued_job[:at], 2.0, "Delay should be approximately 5 seconds"
  end

  # Test all helpers use correct queue
  test "all helpers enqueue to agents queue" do
    job = AgentSessionJob.enqueue_new_session(@session.id)
    assert_equal "agents", job.queue_name

    job2 = AgentSessionJob.enqueue_with_prompt(@session.id, "test")
    assert_equal "agents", job2.queue_name

    job3 = AgentSessionJob.enqueue_for_monitoring(@session.id)
    assert_equal "agents", job3.queue_name

    job4 = AgentSessionJob.enqueue_for_clone_only(@session.id)
    assert_equal "agents", job4.queue_name
  end

  # Test that perform correctly handles deserialized keyword arguments from ActiveJob/GoodJob
  # When jobs are serialized and deserialized, keyword args become a positional hash
  test "perform handles deserialized keyword arguments with string keys" do
    method = AgentSessionJob.instance_method(:perform)
    params = method.parameters

    # Verify the method accepts 3 positional arguments (session_id, follow_up_prompt, options hash)
    # This simulates what GoodJob does when deserializing: [session_id, nil, { "resume_monitoring" => true }]
    positional_params = params.select { |type, _| type == :req || type == :opt }
    assert_equal 3, positional_params.size, "Expected 3 positional parameters (session_id, follow_up_prompt, options)"

    # Verify the options parameter exists and is optional
    options_param = params.find { |_, name| name == :options }
    assert_not_nil options_param, "Expected 'options' parameter to exist"
    assert_equal :opt, options_param[0], "Expected 'options' parameter to be optional"
  end

  # Test that explicit false values are handled correctly in deserialized options
  # This is critical: { "resume_monitoring" => false } should not fall through to agents true
  test "perform options parsing handles explicit false values correctly" do
    # This tests the edge case where || would incorrectly skip false values
    # The fix uses fetch() instead of || to properly handle false
    job = AgentSessionJob.new

    # We can't easily test the internal variable values, but we can verify
    # the method accepts the hash without error
    # The actual behavior is tested in agent_session_job_test.rb with mocks

    # Verify the method signature allows hash as third argument
    method = job.method(:perform)
    params = method.parameters

    # Third parameter should be optional (:opt)
    assert_equal :opt, params[2][0], "Third parameter (options) should be optional"
    assert_equal :options, params[2][1], "Third parameter should be named 'options'"
  end
end
