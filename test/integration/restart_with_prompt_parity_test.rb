# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# Restarting a session that still has a conversation means the same thing through
# all three doors.
#
# The web UI's Restart button, `POST /api/v1/sessions/:id/restart` and MCP
# `action_session`'s `restart` each carried their own verbatim copy of the
# sequence — pick the prompt, pick the key set, clear, release the job id, resume,
# enqueue — and the copies had drifted the same way
# [#508](https://github.com/tadasant/zimmer/issues/508) found for the from-scratch
# branch next door: only the web one retried a dropped Postgres connection, and
# only the web one recorded anything on the session's own timeline. This is the
# retry/recovery slice of [#321](https://github.com/tadasant/zimmer/issues/321).
#
# What this pins is the OPERATION, not the response. Each surface renders its own
# answer — a redirect with a flash, a JSON body, a markdown summary — and that is
# the part that is allowed to differ. Everything that happens to the *session* is
# compared field for field across the three.
class RestartWithPromptParityTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  SURFACES = %i[web api mcp].freeze

  setup do
    @previous_api_keys = ENV["API_KEYS"]
    ENV["API_KEYS"] = "test_api_key_12345"
  end

  teardown do
    ENV["API_KEYS"] = @previous_api_keys
    Mocha::Mockery.instance.teardown
  end

  # A session that got as far as a real conversation and then died: setup is
  # complete (a session_id and a clone), so there IS somewhere to prompt into, and
  # the failure reason is a post-prompt one. It carries a spent retry budget and a
  # scan position, which the two key sets treat differently.
  def failed_mid_conversation_session(failure_reason: "process_crashed")
    Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Fix the auth bug",
      status: :failed,
      session_id: SecureRandom.uuid,
      metadata: {
        "failure_reason" => failure_reason,
        "clone_path" => "/tmp/a-real-clone",
        "working_directory" => "/tmp/a-real-clone",
        "runtime_started" => true,
        "process_pid" => 4242,
        "api_error_retry_count" => 3,
        "paused_by" => "recovery",
        "api_error_last_checked_line" => 91
      }
    )
  end

  def restart_through(surface, session)
    case surface
    when :web
      post restart_session_url(session)
    when :api
      post restart_api_v1_session_path(session.id), headers: { "X-API-Key" => "test_api_key_12345" }
    when :mcp
      Mcp::Tools::ActionSession
        .new(context: Mcp::Context.new(tool_groups: "sessions"))
        .call("action" => "restart", "session_id" => session.id)
    end
  end

  # Written by the web UI's own before_action, not by the restart: a person
  # clicking a button on a session page IS user activity, and an API key or an
  # MCP connection is not. A real difference between the doors rather than drift,
  # so it is normalized away instead of asserted on.
  SURFACE_SPECIFIC_METADATA = %w[last_user_activity_at].freeze

  # Everything a restart does to the session, with the identifiers that cannot
  # match across three different sessions normalized away.
  def observe(session)
    session.reload
    {
      status: session.status,
      session_id_kept: session.session_id.present?,
      running_job_id: session.running_job_id,
      metadata: session.metadata.except(*SURFACE_SPECIFIC_METADATA),
      logs: session.logs.order(:id).pluck(:content, :level),
      enqueued: enqueued_jobs
        .select { |job| job[:job] == AgentSessionJob }
        .map { |job| job[:args].map { |arg| arg == session.id ? :the_session : arg } }
    }
  end

  def observe_restart_through(surface, **session_attrs)
    session = failed_mid_conversation_session(**session_attrs)
    clear_enqueued_jobs
    restart_through(surface, session)
    observe(session)
  end

  # --- the happy path ---------------------------------------------------------

  test "all three surfaces leave the session in the same state" do
    observations = SURFACES.index_with { |surface| observe_restart_through(surface) }

    reference = observations.fetch(:web)
    assert_equal "waiting", reference[:status]

    observations.each do |surface, observed|
      assert_equal reference, observed,
        "the #{surface} surface's restart diverges from the web UI's"
    end
  end

  # Spelled out rather than left implicit in the equality above, so a future
  # change that makes all three wrong in the same way still fails here.
  test "every surface resumes the session, keeps its session_id and enqueues the recovery prompt" do
    SURFACES.each do |surface|
      observed = observe_restart_through(surface)

      assert_equal "waiting", observed[:status], "#{surface} did not resume the session"
      assert observed[:session_id_kept], "#{surface} threw away the conversation it was resuming"
      assert_nil observed[:running_job_id], "#{surface} left the previous job id behind"
      assert_equal [ [ :the_session, AutomatedPrompts::SYSTEM_RECOVERY ] ], observed[:enqueued],
        "#{surface} did not enqueue exactly one recovery turn"
    end
  end

  test "every surface clears the same key set and preserves the same scan position" do
    SURFACES.each do |surface|
      metadata = observe_restart_through(surface)[:metadata]

      Session::STALE_RETRY_METADATA_KEYS.each do |key|
        assert_nil metadata[key], "#{surface} left #{key} behind"
      end
      assert_equal true, metadata["runtime_started"],
        "#{surface} dropped runtime_started on a session with real history to --resume into"
      assert_equal 91, metadata["api_error_last_checked_line"],
        "#{surface} cleared the error-scan position, which no reset policy clears"
    end
  end

  # The one branch where the prompt choice and the key set are the same decision:
  # a session that failed before its initial prompt was ever processed re-sends
  # that prompt, and drops `runtime_started` so the spawn uses `--session-id`
  # rather than `--resume` against a conversation that was never written.
  test "every surface takes the pre-prompt branch identically" do
    SURFACES.each do |surface|
      observed = observe_restart_through(surface, failure_reason: "mcp_connection_failed")

      assert_equal [ [ :the_session, "Fix the auth bug" ] ], observed[:enqueued],
        "#{surface} did not re-send the initial prompt"
      Session::PRE_PROMPT_RESTART_KEYS.each do |key|
        assert_nil observed[:metadata][key], "#{surface} left #{key} behind"
      end
    end
  end

  test "every surface writes the same two log rows" do
    SURFACES.each do |surface|
      contents = observe_restart_through(surface)[:logs].map(&:first)

      assert_includes contents, "Restarting failed session: sending automated recovery prompt"
      assert_includes contents, "Session resumed - its turn is queued for a worker"
    end
  end

  # --- the drift this closed --------------------------------------------------
  #
  # A dropped Postgres connection was retried from the web UI and fatal from the
  # REST API and from MCP. All three retry now, so the attempt count is the same
  # through every door.

  test "every surface retries a dropped connection the same number of times" do
    Sessions::RestartWithPrompt.any_instance.stubs(:sleep)

    attempts = SURFACES.index_with do |surface|
      session = failed_mid_conversation_session
      count = 0

      AgentSessionJob.stub(:enqueue_with_prompt, ->(*, **) {
        count += 1
        raise ActiveRecord::ConnectionNotEstablished, "connection lost"
      }) do
        begin
          restart_through(surface, session)
        rescue Mcp::ToolError
          # MCP renders the refusal as a ToolError; the retrying is the point here.
        end
      end

      assert_equal "failed", session.reload.status, "#{surface} did not roll the restart back"
      count
    end

    assert_equal 3, attempts[:web], "the web UI's retry budget changed"
    assert_equal 1, attempts.values.uniq.length,
      "the three surfaces spend different retry budgets on a dropped connection: #{attempts.inspect}"
  end

  # The web UI's retry used to live in ControllerDatabaseRetry, whose give-up path
  # renders a 503 (or redirects) *and* returns false — and #restart's caller, alone
  # among the six, had no `performed?` guard, so the action died of a double
  # render. With the retry in the service there is one render, and the person
  # clicking Restart is told what happened.
  test "the web UI reports an exhausted retry as a redirect with an alert, not a double render" do
    Sessions::RestartWithPrompt.any_instance.stubs(:sleep)
    session = failed_mid_conversation_session

    AgentSessionJob.stub(:enqueue_with_prompt, ->(*, **) {
      raise ActiveRecord::ConnectionNotEstablished, "connection lost"
    }) do
      post restart_session_url(session)
    end

    assert_redirected_to session_path(session)
    assert_match(/high server activity/, flash[:alert])
  end

  # The REST API answers 503 rather than the 500 it raised before the retry moved
  # into the service: a dropped connection is a transport failure the caller
  # should retry, not a rejected request.
  test "the REST API reports an exhausted retry as a retryable 503" do
    Sessions::RestartWithPrompt.any_instance.stubs(:sleep)
    session = failed_mid_conversation_session

    AgentSessionJob.stub(:enqueue_with_prompt, ->(*, **) {
      raise ActiveRecord::ConnectionNotEstablished, "connection lost"
    }) do
      post restart_api_v1_session_path(session.id), headers: { "X-API-Key" => "test_api_key_12345" }
    end

    assert_response :service_unavailable
    assert_equal "Service unavailable", JSON.parse(response.body)["error"]
    assert_match(/high server activity/, JSON.parse(response.body)["message"])
  end

  # --- the preconditions that stayed at the surface ---------------------------
  #
  # The `session_id` check is a precondition all three make and all three phrase
  # differently; the sentence is part of each surface's contract, so it stayed
  # where it was rather than moving into the shared service.

  test "every surface refuses a session with a transcript to lose and no session_id" do
    SURFACES.each do |surface|
      session = failed_mid_conversation_session
      # A blank session_id with a transcript to lose is the shape
      # #needs_restart_from_scratch? deliberately does not claim.
      session.update_columns(session_id: nil, transcript: '{"type":"user"}')
      assert_not session.reload.needs_restart_from_scratch?
      clear_enqueued_jobs

      assert_no_enqueued_jobs(only: AgentSessionJob) do
        begin
          restart_through(surface, session.reload)
        rescue Mcp::ToolError => e
          assert_equal "Session has no session_id", e.message
        end
      end

      assert_equal "failed", session.reload.status,
        "#{surface} moved a session it could not restart"
    end
  end
end
