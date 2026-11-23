# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# The deployment switch, ZIMMER_TOKEN_BROKER_ENABLED, at every consumer.
#
# The regression this pins: a catalog is shared between deployments. One that
# never set the broker up, running a catalog whose entries already declare
# `brokered_auth` and still carry their static header, must behave exactly as if
# the declaration were not there. Every "off" test below therefore compares the
# declaring entry against the same entry WITHOUT the declaration, rather than
# against an expectation written by hand, and does so with a usable grant in the
# database and the identity configured as well as without: only the switch counts.
class TokenBrokerSwitchTest < ActiveSupport::TestCase
  include TokenBrokerTestHelpers

  STATIC_KEY = "static-strad-key-0123456789abcdef"

  RUNTIMES = {
    claude: [ ClaudeMcpConfigPostProcessor, ".mcp.json" ],
    codex: [ CodexConfigTomlPostProcessor, ".codex/config.toml" ],
    pi: [ PiMcpConfigPostProcessor, ".mcp.json" ]
  }.freeze

  setup do
    @strad = FakeStrad.new
    client = @strad.client
    TokenBroker::Client.stubs(:new).returns(client)
    @session = sessions(:active_session)
    @session.update_columns(mcp_servers: %w[image-diff], metadata: { "agent_root_key" => "general-agent" })
    @dir = Dir.mktmpdir("broker-switch")
    @saved_env = ENV.to_hash.slice("STRAD_API_KEY", "ZIMMER_LOCAL_API_KEY")
    ENV["STRAD_API_KEY"] = STATIC_KEY
    ENV["ZIMMER_LOCAL_API_KEY"] ||= "local-test-key"
    SecretProviders.reset!
  end

  teardown do
    FileUtils.remove_entry(@dir) if File.exist?(@dir)
    %w[STRAD_API_KEY ZIMMER_LOCAL_API_KEY].each { |k| ENV.delete(k) }
    @saved_env.each { |k, v| ENV[k] = v }
    SecretProviders.reset!
  end

  # --- the switch itself --------------------------------------------------

  test "unset, blank and false-like values are off" do
    [ nil, "", "  ", "0", "false", "FALSE", " False ", "f", "no", "n", "off", "disabled" ].each do |value|
      refute TokenBroker.enabled?(TokenBroker::ENABLED_ENV => value), "#{value.inspect} must be off"
    end
  end

  test "any other value is on, including one nobody recognises or that is not valid UTF-8" do
    [ "1", "true", "yes", "on", "enabled", "flase", "ture", "\xFF".dup.force_encoding("UTF-8") ].each do |value|
      assert TokenBroker.enabled?(TokenBroker::ENABLED_ENV => value), "#{value.inspect} must be on"
    end
  end

  test "neither the client identity nor a grant turns the broker on" do
    with_catalog(declared: true) do |server|
      with_oauth_client_identity do
        @strad.create_grant!
        assert server.declares_brokered_auth?
        refute server.brokered?
        assert_empty TokenBroker.brokered_among(%w[image-diff])
      end
    end
  end

  # --- off: identical to the same entry without the declaration -----------

  RUNTIMES.each_key do |runtime|
    [ true, false ].each do |mint|
      test "off, #{runtime}, #{mint ? 'at a turn start' : 'outside one'}: the written config is byte-identical to an undeclared entry's" do
        both_grant_states do |label|
          undeclared = with_catalog(declared: false) { prepared(runtime, mint) }
          declared = with_catalog(declared: true) { prepared(runtime, mint) }

          assert_equal undeclared, declared, label
          assert_includes declared, "image-diff", "#{label}: the entry must still be there"
          assert_includes declared, (runtime == :codex ? "STRAD_API_KEY" : STATIC_KEY), "#{label}: with its own credential"
        end
        assert_empty @strad.requests
        assert_equal 0, McpBrokeredToken.count
      end
    end
  end

  test "off: session_variables keeps the static credential variable" do
    both_grant_states do |label|
      undeclared = with_catalog(declared: false, &:session_variables)
      declared = with_catalog(declared: true, &:session_variables)

      assert_equal [ "STRAD_API_KEY" ], declared, label
      assert_equal undeclared, declared, label
    end
  end

  test "off: Zimmer's own calls send the entry's static header" do
    both_grant_states do |label|
      undeclared = with_catalog(declared: false) { |server| McpServerEndpoint.new(server).headers }
      declared = with_catalog(declared: true) { |server| McpServerEndpoint.new(server).headers }

      assert_equal({ "Authorization" => "Bearer #{STATIC_KEY}" }, declared, label)
      assert_equal undeclared, declared, label
    end
    assert_empty @strad.requests
  end

  test "off: connector status is the same in every field, and only the note differs" do
    both_grant_states do |label|
      undeclared = with_catalog(declared: false) { ConnectorStatusProbe.for("image-diff") }
      declared = with_catalog(declared: true) { ConnectorStatusProbe.for("image-diff") }

      %i[state label summary available? actionable? authorizable? unavailable_reason missing_variables error_message instructions].each do |field|
        expected = undeclared.public_send(field)
        actual = declared.public_send(field)
        expected.nil? ? assert_nil(actual, "#{label}: #{field}") : assert_equal(expected, actual, "#{label}: #{field}")
      end
      assert_equal :ready, declared.state, label
      assert_nil undeclared.broker_off_note
      assert_match(/broker is off on this deployment \(ZIMMER_TOKEN_BROKER_ENABLED\)/, declared.broker_off_note)
    end
  end

  test "off: the status of an entry whose static variable is missing is unchanged too" do
    ENV.delete("STRAD_API_KEY")
    SecretProviders.reset!
    undeclared = with_catalog(declared: false) { ConnectorStatusProbe.for("image-diff") }
    declared = with_catalog(declared: true) { ConnectorStatusProbe.for("image-diff") }

    assert_equal :missing_configuration, declared.state
    assert_equal undeclared.unavailable_reason, declared.unavailable_reason
  end

  test "off: the OAuth injector treats a header-less entry as it would undeclared" do
    results = [ false, true ].map do |declared|
      with_catalog(declared: declared, headers: {}) do
        injector = McpOauthCredentialInjector.new(@session, working_directory: @dir)
        [ McpOauthCredentialInjector.oauth_capable_server?("image-diff"), injector.send(:mcp_servers) ]
      end
    end

    assert_equal results.first, results.last
    assert_equal true, results.last.first
  end

  test "off: the reused-clone path re-prepares nothing" do
    with_catalog(declared: true) do
      AirPrepareService.expects(:new).never
      assert_nil AgentSessionJob.new.send(:remint_brokered_tokens_for_reused_clone, @session, @dir, LogBuffer.new(@session))
    end
  end

  test "off: a malformed declaration is inert as well" do
    with_catalog(declared: true, declaration: { "scopes" => "not-a-list" }) do |server|
      refute server.brokered?
      assert_equal "Bearer #{STATIC_KEY}", McpServerEndpoint.new(server).headers["Authorization"]
    end
  end

  test "off: the broker's own entry points mint nothing, whoever calls them" do
    with_catalog(declared: true) do |server|
      with_oauth_client_identity do
        @strad.create_grant!
        refute TokenBroker.mint_for_session(@session, %w[image-diff]).any?
        assert_nil TokenBroker.readiness_problem(server)
        error = assert_raises(TokenBroker::MintError) { TokenBroker.backend_token(server) }
        assert_match(/broker is off/, error.message)
      end
    end
    assert_empty @strad.requests
  end

  # Turning it off must still clean up what was minted while it was on.
  test "off: a token minted while it was on is still revoked" do
    with_oauth_client_identity do
      @strad.create_grant!
      turn_token_broker_on
      with_catalog(declared: true) { TokenBroker.mint_for_session(@session, %w[image-diff]) }
      turn_token_broker_off

      assert_equal 1, TokenBroker.revoke_session_tokens(@session.id)
      assert_equal "revoked", McpBrokeredToken.sole.state
    end
  end

  test "off: the sweep still revokes a child left live at rest" do
    with_oauth_client_identity do
      @strad.create_grant!
      turn_token_broker_on
      with_catalog(declared: true) { TokenBroker.mint_for_session(@session, %w[image-diff]) }
      turn_token_broker_off
      @session.update_columns(status: Session.statuses[:needs_input])
      McpBrokeredToken.sole.update_columns(created_at: 1.hour.ago)

      TokenBrokerSweepJob.perform_now

      assert_equal "revoked", McpBrokeredToken.sole.state
    end
  end

  # --- on, and able to mint ------------------------------------------------

  test "on with a grant: every consumer uses the broker, none the static key" do
    turn_token_broker_on
    with_oauth_client_identity do
      @strad.create_grant!
      with_catalog(declared: true) do |server|
        assert server.brokered?
        assert_empty server.session_variables
        assert_match(/\ABearer strad_oat_/, McpServerEndpoint.new(server).headers["Authorization"])
        status = ConnectorStatusProbe.for("image-diff")
        assert_equal :ready, status.state
        assert_nil status.broker_off_note
        assert_empty McpOauthCredentialInjector.new(@session, working_directory: @dir).send(:mcp_servers)
        refute McpOauthCredentialInjector.oauth_capable_server?("image-diff")

        RUNTIMES.each_key do |runtime|
          text = prepared(runtime, true)
          assert_includes text, "strad_oat_", runtime
          refute_includes text, STATIC_KEY, runtime
          refute_includes text, "STRAD_API_KEY", runtime
        end
      end
    end
  end

  # --- on, and unable to mint: never the static key ------------------------

  test "on, identity not configured: the entry is absent and nothing reaches the static key" do
    assert_fails_closed
  end

  test "on, no grant connected: the entry is absent and nothing reaches the static key" do
    with_oauth_client_identity { assert_fails_closed }
  end

  test "on, the grant needs consent again: the entry is absent and nothing reaches the static key" do
    with_oauth_client_identity do
      @strad.create_grant!.update!(status: "needs_consent")
      assert_fails_closed
    end
  end

  test "on, a malformed declaration: the entry is absent and nothing reaches the static key" do
    with_oauth_client_identity do
      @strad.create_grant!
      assert_fails_closed(declaration: { "scopes" => "not-a-list" })
    end
  end

  test "on, a switch value nobody recognises: fails closed like on, not open like off" do
    ENV[TokenBroker::ENABLED_ENV] = "ture"
    assert_fails_closed(turn_on: false)
  end

  private

  def assert_fails_closed(declaration: { "scopes" => [ "slug:image-diff" ] }, turn_on: true)
    turn_token_broker_on if turn_on
    with_catalog(declared: true, declaration: declaration) do |server|
      RUNTIMES.each_key do |runtime|
        text = prepared(runtime, true)
        refute_includes text, "image-diff", runtime
        refute_includes text, STATIC_KEY, runtime
        refute_includes text, "STRAD_API_KEY", runtime
      end
      assert_empty server.session_variables
      assert_empty McpOauthCredentialInjector.new(@session, working_directory: @dir).send(:mcp_servers)
      assert_raises(McpServerEndpoint::UnresolvableError) { McpServerEndpoint.new(server).headers }
      status = ConnectorStatusProbe.for("image-diff")
      assert_equal :broker_not_ready, status.state
      refute status.available?
      assert_nil status.broker_off_note
    end
  end

  # Yields with nothing set up, then with the identity configured and a usable
  # grant, so "off" is shown to depend on neither.
  def both_grant_states
    yield "no identity, no grant"
    with_oauth_client_identity do
      @strad.create_grant!
      yield "identity and grant"
    end
  end

  def with_catalog(declared:, headers: nil, declaration: { "scopes" => [ "slug:image-diff" ] })
    entry = static_strad_entry("image-diff")
    entry["headers"] = headers unless headers.nil?
    entry["brokered_auth"] = declaration if declared
    stub_mcp_catalog("image-diff" => entry)
    yield ServersConfig.find("image-diff")
  end

  # Run one runtime's real prepare step over what AIR would have written, and
  # return the bytes it left.
  def prepared(runtime, mint)
    klass, path = RUNTIMES.fetch(runtime)
    fs = MockFileSystemAdapter.new
    full = File.join(@dir, path)
    url = "#{FakeStrad::ORIGIN}/mcp?servers=image-diff"
    case runtime
    when :codex
      fs.write(full, TomlRB.dump("mcp_servers" => { "image-diff" => { "url" => url, "bearer_token_env_var" => "STRAD_API_KEY" } }))
    when :claude
      fs.write(full, JSON.pretty_generate("mcpServers" => { "image-diff" => {
        "type" => "http", "url" => url, "headers" => { "Authorization" => "Bearer ${STRAD_API_KEY}" }
      } }))
    end
    processor = klass.new(session: @session, working_directory: @dir, file_system: fs)
    processor.mint_brokered_tokens = mint
    processor.post_process!
    fs.read(full)
  end
end
