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

  # --- the entry conditions ---------------------------------------------------
  #
  # The operation is shared; the authorization is not, and the doors are allowed
  # to disagree. What they may NOT do is let an agent restart a session a human
  # cannot — which is what the web door's own `failed?` guard did until
  # [#830](https://github.com/tadasant/zimmer/issues/830). These two tests pin the
  # agreement and the one remaining, deliberate difference.

  # Any STATUS the web UI offers Restart for, the other two doors accept.
  test "the web door never accepts a status MCP and REST would refuse" do
    %i[needs_input failed].each do |status|
      SURFACES.each do |surface|
        session = Session.create!(
          git_root: "https://github.com/test/repo.git",
          prompt: "Fix the auth bug",
          status: status
        )
        assert session.restartable_by_hand?, "#{status} should be restartable by hand"

        clear_enqueued_jobs
        restart_through(surface, session)

        assert_equal "waiting", session.reload.status,
          "#{surface} refused a #{status} session the web UI offers a Restart button for"
      end
    end
  end

  # `waiting` is the difference, and it runs the safe way round: the two
  # non-interactive doors still accept a stalled waiting session (that is what the
  # awaken-waiting-sessions sweep is built on), and the web door does not offer a
  # button for one, because a waiting session is in flight rather than stranded.
  test "the web door alone refuses a waiting session" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Fix the auth bug",
      status: :waiting
    )

    assert session.may_resume?, "waiting is a state MCP and REST accept"
    assert_not session.restartable_by_hand?

    post restart_session_url(session)

    assert_redirected_to session_path(session)
    assert_match(/Cannot restart a session that is waiting/, flash[:alert])
    assert_equal "waiting", session.reload.status
  end

  # The armed-wake divergence, pinned as the deliberate thing it is rather than
  # left to be rediscovered. `#paused_until_scheduled_time?` is status-agnostic, so
  # a `needs_input` session can be asleep on a one-time wake — a follow-up
  # preserves those rather than consuming them. MCP and the REST API refuse such a
  # session outright; the web UI's Restart button consumes the wake and takes the
  # session over, which is the interactive-door distinction
  # `Sessions::RestartFromScratch`'s header already draws and is older than #830.
  test "a needs_input session asleep on a wake: MCP and REST refuse it, the web door takes it over" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Fix the auth bug",
      status: :needs_input,
      session_id: SecureRandom.uuid
    )
    Trigger.create!(
      name: "Wake session ##{session.id}",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "Wake up",
      reuse_session: true,
      last_session_id: session.id,
      trigger_conditions_attributes: [
        { condition_type: "schedule",
          configuration: { "scheduled_at" => 3.hours.from_now.utc.iso8601, "timezone" => "UTC" } }
      ]
    )
    # Creating the wake sleeps the session; #830's subject is the needs_input one.
    session.update_columns(status: "needs_input")

    assert session.paused_until_scheduled_time?
    assert session.restartable_by_hand?,
      "the web door offers Restart here on purpose — a person clicking it is taking the session over"

    error = assert_raises(Mcp::ToolError) do
      restart_through(:mcp, session)
    end
    assert_match(/asleep on a wake-up it has not reached yet/, error.message)

    restart_through(:api, session)
    assert_response :unprocessable_entity
    assert_match(/asleep on a wake-up it has not reached yet/, JSON.parse(response.body)["message"])
    assert_equal "needs_input", session.reload.status, "neither non-interactive door may start it"

    restart_through(:web, session)
    assert_equal "waiting", session.reload.status, "the web door takes it over"
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
