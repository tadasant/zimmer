# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# Both runtimes must hand their MCP servers the address of Zimmer's approval
# endpoint. Neither did: Claude set only ELICITATION_SESSION_ID and Codex set
# nothing, leaving @pulsemcp/mcp-elicitation on its built-in default
# (http://zimmer/…, a Tailscale name that does not resolve where agents run).
# Every approval request therefore failed silently and every gated reveal came
# back redacted.
class CliSpawnEnvElicitationTest < ActiveSupport::TestCase
  # Minimal host for the shared module, matching what the real adapters expose.
  class Host
    include CliSpawnEnv

    def initialize(session_id:, logger:)
      @zimmer_session_id = session_id
      @logger = logger
    end

    def apply!(env_vars)
      apply_elicitation_env(env_vars)
    end
  end

  setup do
    AppUrl.stubs(:base_url).returns("https://zimmer.example.com")
    @logger = stub_everything("logger")
  end

  test "points MCP servers at this Zimmer's elicitation endpoint" do
    env = Host.new(session_id: 886, logger: @logger).apply!({})

    assert_equal "https://zimmer.example.com/api/v1/elicitations", env["ELICITATION_REQUEST_URL"]
    assert_equal "886", env["ELICITATION_SESSION_ID"]
    # Deliberately absent: whether a server gates an action stays that server's call.
    assert_not env.key?("ELICITATION_ENABLED")
  end

  test "an explicit value from the session .env wins" do
    env = Host.new(session_id: 886, logger: @logger).apply!(
      "ELICITATION_REQUEST_URL" => "https://other.example.com/api/v1/elicitations"
    )

    assert_equal "https://other.example.com/api/v1/elicitations", env["ELICITATION_REQUEST_URL"]
  end

  test "sets the URL even for a session-less spawn" do
    env = Host.new(session_id: nil, logger: @logger).apply!({})

    assert_equal "https://zimmer.example.com/api/v1/elicitations", env["ELICITATION_REQUEST_URL"]
    assert_nil env["ELICITATION_SESSION_ID"]
  end

  test "a failure to resolve the endpoint never breaks the spawn" do
    ElicitationEndpoint.stubs(:spawn_env).raises(RuntimeError, "boom")

    env = nil
    assert_nothing_raised { env = Host.new(session_id: 886, logger: @logger).apply!({ "PATH" => "/usr/bin" }) }
    assert_equal "/usr/bin", env["PATH"]
  end
end
