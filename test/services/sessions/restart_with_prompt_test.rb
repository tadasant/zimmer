# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class Sessions::RestartWithPromptTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  def failed_session(**attrs)
    Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Fix the auth bug",
      status: :failed,
      session_id: SecureRandom.uuid,
      metadata: { "failure_reason" => "process_crashed", "runtime_started" => true },
      **attrs
    )
  end

  # --- the happy path ---------------------------------------------------------

  test "resumes the session and enqueues the automated recovery prompt" do
    session = failed_session

    result = nil
    assert_enqueued_with(job: AgentSessionJob, args: [ session.id, AutomatedPrompts::SYSTEM_RECOVERY ]) do
      result = Sessions::RestartWithPrompt.call(session, actor: :web)
    end

    assert result.ok?
    assert_nil result.error
    assert_nil result.error_code
    assert_equal "waiting", session.reload.status
    assert_nil session.running_job_id
  end

  test "re-sends the initial prompt when the session failed before it was ever processed" do
    session = failed_session(metadata: { "failure_reason" => "mcp_connection_failed" })
    assert session.failed_before_initial_prompt?

    assert_enqueued_with(job: AgentSessionJob, args: [ session.id, "Fix the auth bug" ]) do
      assert Sessions::RestartWithPrompt.call(session, actor: :api).ok?
    end
  end

  # --- the key set ------------------------------------------------------------
  #
  # The whole reason the prompt choice and the key set cannot be separated: a
  # pre-prompt failure drops `runtime_started` as well, so the replacement spawn
  # uses `--session-id` rather than `--resume` against a conversation that was
  # never written.

  test "an ordinary restart clears the stale retry keys and keeps runtime_started" do
    session = failed_session(metadata: {
      "failure_reason" => "process_crashed",
      "runtime_started" => true,
      "process_pid" => 4242,
      "api_error_retry_count" => 3,
      "api_error_last_checked_line" => 91
    })

    assert Sessions::RestartWithPrompt.call(session, actor: :mcp).ok?

    metadata = session.reload.metadata
    Session::STALE_RETRY_METADATA_KEYS.each { |key| assert_nil metadata[key], "left #{key} behind" }
    assert_equal true, metadata["runtime_started"],
      "an ordinary restart has real history to --resume into"
    assert_equal 91, metadata["api_error_last_checked_line"],
      "cleared the error-scan position, which no reset policy clears"
  end

  test "a pre-prompt restart clears runtime_started too" do
    session = failed_session(metadata: { "failure_reason" => "mcp_connection_failed", "runtime_started" => true })

    assert Sessions::RestartWithPrompt.call(session, actor: :web).ok?

    metadata = session.reload.metadata
    Session::PRE_PROMPT_RESTART_KEYS.each { |key| assert_nil metadata[key], "left #{key} behind" }
  end

  # --- the timeline -----------------------------------------------------------

  test "writes the two log rows the surfaces used to write themselves" do
    session = failed_session

    Sessions::RestartWithPrompt.call(session, actor: :api)

    assert session.logs.where(content: "Restarting failed session: sending automated recovery prompt").exists?
    assert session.logs.where(content: "Session resumed - its turn is queued for a worker").exists?
  end

  test "names the state the restart was asked from, not the waiting it lands in" do
    {
      failed: "Restarting failed session",
      waiting: "Continuing waiting session",
      needs_input: "Continuing paused session"
    }.each do |status, description|
      session = failed_session(status: status)

      Sessions::RestartWithPrompt.call(session, actor: :web)

      assert session.logs.where("content LIKE ?", "#{description}%").exists?,
        "a #{status} session was described as something else"
    end
  end

  # --- the failure paths ------------------------------------------------------

  test "retries a dropped connection and rolls the restart back when it gives up" do
    Sessions::RestartWithPrompt.any_instance.stubs(:sleep)
    session = failed_session
    attempts = 0

    result = AgentSessionJob.stub(:enqueue_with_prompt, ->(*, **) {
      attempts += 1
      raise ActiveRecord::ConnectionNotEstablished, "connection lost"
    }) do
      Sessions::RestartWithPrompt.call(session, actor: :mcp)
    end

    assert_equal 3, attempts, "the retry budget changed"
    assert_not result.ok?
    assert_equal :database_unavailable, result.error_code
    assert_match(/high server activity/, result.error)
    assert_equal "failed", session.reload.status, "the restart was not rolled back"
    assert_equal "process_crashed", session.metadata["failure_reason"], "the metadata clear was not rolled back"
  end

  test "reports an unexpected failure rather than letting it escape to the surface" do
    session = failed_session

    ErrorReporter.expects(:report_exception).once
    result = AgentSessionJob.stub(:enqueue_with_prompt, ->(*, **) { raise "boom" }) do
      Sessions::RestartWithPrompt.call(session, actor: :api)
    end

    assert_not result.ok?
    assert_equal :failed, result.error_code
    assert_equal "boom", result.error
    assert_equal "failed", session.reload.status
    assert session.logs.where("content LIKE ?", "Error resuming session: boom%").exists?
  end
end
