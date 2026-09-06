# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# Restart from scratch means the same thing through all three doors.
#
# The web UI's Restart button, `POST /api/v1/sessions/:id/restart` and MCP
# `action_session`'s `restart` each carried their own verbatim copy of this
# sequence, and the copies had drifted: only the web one retried a dropped
# Postgres connection, so a transient blip during a restart was survivable from
# the browser and a 500 or a `ToolError` from the other two — on the one operation
# whose point is recovering a session that is already broken
# ([#508](https://github.com/tadasant/zimmer/issues/508)).
#
# What this pins is the OPERATION, not the response. Each surface renders its own
# answer — a redirect with a flash, a JSON body, a markdown summary — and that is
# the part that is allowed to differ. Everything that happens to the *session* is
# compared field for field across the three.
class RestartFromScratchParityTest < ActionDispatch::IntegrationTest
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

  # A session that failed before setup ever completed: no clone, no session_id, a
  # half-written set of setup artifacts, a spent retry budget and a spot-hold
  # ladder. Every surface should leave it in exactly the same state.
  def broken_before_setup_session
    Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Fix the auth bug",
      status: :failed,
      metadata: {
        "failure_reason" => "git_clone_failed",
        "clone_path" => "/tmp/half-a-clone",
        "working_directory" => "/tmp/half-a-clone",
        "runtime_started" => true,
        "process_pid" => 4242,
        "api_error_retry_count" => 3,
        "paused_by" => "recovery",
        SpotSessionHold::HELD_COUNT => 3,
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

  # Everything a restart from scratch does to the session, with the identifiers
  # that cannot match across three different sessions normalized away.
  def observe(session)
    session.reload
    {
      status: session.status,
      session_id: session.session_id,
      running_job_id_recorded: session.running_job_id.present?,
      metadata: session.metadata.except(*SURFACE_SPECIFIC_METADATA),
      logs: session.logs.order(:id).pluck(:content, :level),
      enqueued: enqueued_jobs
        .select { |job| job[:job] == AgentSessionJob }
        .map { |job| job[:args].map { |arg| arg == session.id ? :the_session : arg } }
    }
  end

  def observe_restart_through(surface)
    session = broken_before_setup_session
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
        "the #{surface} surface's restart from scratch diverges from the web UI's"
    end
  end

  # Spelled out rather than left implicit in the equality above, so a future
  # change that makes all three wrong in the same way still fails here.
  test "every surface resumes the session, drops its session_id and enqueues one fresh first turn" do
    SURFACES.each do |surface|
      observed = observe_restart_through(surface)

      assert_equal "waiting", observed[:status], "#{surface} did not resume the session"
      assert_nil observed[:session_id], "#{surface} left a session_id behind"
      assert_equal [ [ :the_session ] ], observed[:enqueued],
        "#{surface} did not enqueue exactly one fresh first turn"
      assert observed[:running_job_id_recorded],
        "#{surface} left the session running with no tracked job"
    end
  end

  test "every surface clears the same key set and preserves the same scan position" do
    SURFACES.each do |surface|
      metadata = observe_restart_through(surface)[:metadata]

      Session::RESTART_FROM_SCRATCH_KEYS.each do |key|
        assert_nil metadata[key], "#{surface} left #{key} behind"
      end
      assert_equal 91, metadata["api_error_last_checked_line"],
        "#{surface} cleared the error-scan position, which no reset policy clears"
    end
  end

  test "every surface writes the same two log rows" do
    SURFACES.each do |surface|
      contents = observe_restart_through(surface)[:logs].map(&:first)

      assert_includes contents, "Restarting session from scratch: re-running full setup pipeline " \
                                "(git clone, MCP config, process spawn)"
      assert_includes contents, "Session resumed - its turn is queued for a worker, full setup will be re-attempted"
    end
  end

  # --- the refusal ------------------------------------------------------------

  test "every surface refuses a session with no git_root, identically, and records why" do
    SURFACES.each do |surface|
      session = broken_before_setup_session
      session.update_column(:git_root, nil)
      clear_enqueued_jobs

      assert_no_enqueued_jobs(only: AgentSessionJob) do
        begin
          restart_through(surface, session.reload)
        rescue Mcp::ToolError => e
          assert_equal "cannot restart from scratch: no git_root configured", e.message,
            "#{surface} refused with a different sentence"
        end
      end

      session.reload
      assert_equal "failed", session.status, "#{surface} moved a session it refused to restart"
      assert session.logs.where(
        "content LIKE ?", "%cannot restart from scratch: no git_root configured%"
      ).exists?, "#{surface} refused the restart without recording it on the session's timeline"
    end
  end

  # --- the drift this closed --------------------------------------------------
  #
  # The headline of #508. A dropped Postgres connection was retried from the web
  # UI and fatal from the REST API and from MCP. All three retry now, so the
  # attempt count is the same through every door.

  test "every surface retries a dropped connection the same number of times" do
    Sessions::RestartFromScratch.any_instance.stubs(:sleep)

    attempts = SURFACES.index_with do |surface|
      session = broken_before_setup_session
      count = 0

      AgentSessionJob.stub(:enqueue_new_session, ->(*, **) {
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
  # renders a 503 (or redirects) *and* returns false — so the caller then rendered
  # its own redirect on top and the action died of a double render. With the retry
  # in the service there is one render, and the person clicking Restart is told
  # what happened.
  test "the web UI reports an exhausted retry as a redirect with an alert, not a double render" do
    Sessions::RestartFromScratch.any_instance.stubs(:sleep)
    session = broken_before_setup_session

    AgentSessionJob.stub(:enqueue_new_session, ->(*, **) {
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
    Sessions::RestartFromScratch.any_instance.stubs(:sleep)
    session = broken_before_setup_session

    AgentSessionJob.stub(:enqueue_new_session, ->(*, **) {
      raise ActiveRecord::ConnectionNotEstablished, "connection lost"
    }) do
      post restart_api_v1_session_path(session.id), headers: { "X-API-Key" => "test_api_key_12345" }
    end

    assert_response :service_unavailable
    assert_equal "Service unavailable", JSON.parse(response.body)["error"]
    assert_match(/high server activity/, JSON.parse(response.body)["message"])
  end
end
