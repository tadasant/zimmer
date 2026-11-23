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

      %i[state label summary available? actionable? authorizable? unavailable_reason missing_variables error_message instructions
         variable_sources credential expires_at oauth_determination].each do |field|
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

  # The cutover's first three steps: declare while off, connect while off. Neither
  # may change what a session gets.
  test "off, declared, no grant: Connect succeeds, and a session started before and after it is byte-identical to today" do
    today = RUNTIMES.keys.index_with { |runtime| with_catalog(declared: false) { prepared(runtime, true) } }

    with_oauth_client_identity do
      with_catalog(declared: true) do |server|
        RUNTIMES.each_key { |runtime| assert_equal today[runtime], prepared(runtime, true), "#{runtime} before Connect" }
        headers_before = McpServerEndpoint.new(server).headers

        @strad.create_grant!

        RUNTIMES.each_key { |runtime| assert_equal today[runtime], prepared(runtime, true), "#{runtime} after Connect" }
        assert_equal headers_before, McpServerEndpoint.new(server).headers
        assert_equal [ "STRAD_API_KEY" ], server.session_variables
        assert_equal 0, McpBrokeredToken.count
        assert_empty @strad.exchanges

        # And only then the switch: the entry already has a grant.
        turn_token_broker_on
        assert_nil TokenBroker.readiness_problem(server)
        assert_includes prepared(:claude, true), "strad_oat_"
      end
    end
  end

  # --- on, then off: no trace of the broker is left -------------------------

  RUNTIMES.each_key do |runtime|
    test "on then off, #{runtime}: a file the broker wrote becomes the undeclared entry's file again" do
      today = with_catalog(declared: false) { prepared(runtime, true) }
      fs = MockFileSystemAdapter.new

      with_oauth_client_identity do
        @strad.create_grant!
        with_catalog(declared: true) do
          turn_token_broker_on
          assert_includes prepared(runtime, true, fs: fs), "strad_oat_"
          assert_equal [ "image-diff" ], @session.reload.metadata[RuntimeConfigPostProcessor::BROKERED_ENTRIES_KEY]

          turn_token_broker_off
          assert_equal today, prepared(runtime, true, fs: fs)
          refute @session.reload.metadata.key?(RuntimeConfigPostProcessor::BROKERED_ENTRIES_KEY), "the record is cleared once nothing of the broker's is left"
        end
      end
    end
  end

  test "pi, on: a later turn replaces the previous turn's token rather than keeping it" do
    fs = MockFileSystemAdapter.new
    turn_token_broker_on
    with_oauth_client_identity do
      @strad.create_grant!
      with_catalog(declared: true) do
        first = prepared(:pi, true, fs: fs)
        second = prepared(:pi, true, fs: fs)
        assert_not_equal first, second
        assert_includes second, McpBrokeredToken.order(:id).last.token
      end
    end
  end

  test "pi, off and never on: an entry already in the file is left alone, as it always was" do
    fs = MockFileSystemAdapter.new
    with_catalog(declared: true) do
      fs.write(File.join(@dir, RUNTIMES[:pi].last), JSON.generate("mcpServers" => { "image-diff" => { "type" => "http", "url" => "https://local.example.com/mcp" } }))
      assert_includes prepared(:pi, true, fs: fs), "https://local.example.com/mcp"
    end
  end

  test "on then off: the reused-clone path re-prepares a session whose config the broker shaped, even one it only removed an entry from" do
    @session.merge_metadata!(RuntimeConfigPostProcessor::BROKERED_ENTRIES_KEY => [ "image-diff" ])
    prepare = stub(prepare!: true, injected_mcp_servers: [], brokered_token_result: TokenBroker::MintResult.empty)
    AirPrepareService.expects(:new).returns(prepare)

    with_catalog(declared: true) do
      assert_equal :reprepared, AgentSessionJob.new.send(:remint_brokered_tokens_for_reused_clone, @session, @dir, LogBuffer.new(@session))
    end
  end

  test "a server the broker no longer leaves out stops being recorded as degraded" do
    broker = { "name" => "image-diff", "error" => "token_broker_unavailable", "reason" => "x" }
    other = { "name" => "granola", "error" => "timeout", "reason" => "y" }
    @session.merge_metadata!("mcp_degraded_servers" => [ broker, other ])

    AgentSessionJob.new.send(:report_brokered_tokens, @session, stub(brokered_token_result: TokenBroker::MintResult.empty), LogBuffer.new(@session))

    assert_equal %w[granola], @session.reload.degraded_mcp_servers.map { |e| e["name"] }
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

  test "on, the declaration is null: malformed, not absent" do
    assert_fails_closed(declaration: nil)
  end

  test "on, strad is down: the entry is absent and nothing reaches the static key" do
    with_oauth_client_identity do
      @strad.create_grant!
      TokenBroker::Client.any_instance.stubs(:exchange).raises(TokenBroker::Client::Error, "HTTP 503")
      TokenBroker.stubs(:exchange!).raises(TokenBroker::MintError, "HTTP 503")
      assert_fails_closed(readiness: false)
    end
  end

  test "on, the signer is unavailable: the entry is absent and nothing reaches the static key" do
    with_oauth_client_identity do
      @strad.create_grant!
      TokenBroker.stubs(:exchange!).raises(TokenBroker::MintError, "KMS could not be reached")
      assert_fails_closed(readiness: false)
    end
  end

  test "on, minting raises something nobody expected: the entry is absent in every runtime" do
    turn_token_broker_on
    TokenBroker.stubs(:mint_for_session).raises(RuntimeError, "boom")
    with_catalog(declared: true) do
      RUNTIMES.each_key do |runtime|
        text = prepared(runtime, true)
        refute_includes text, "image-diff", runtime
        refute_includes text, STATIC_KEY, runtime
      end
    end
  end

  # The catalog reader degrades to an empty list, which reads exactly like
  # "nothing is brokered".
  test "on, the catalog cannot be read: a remote entry is dropped with a cause, not given its static key" do
    turn_token_broker_on
    with_catalog(declared: true) do
      ServersConfig.stubs(:all).returns([])
      ServersConfig.stubs(:all!).raises(AirCatalogService::CatalogError, "down")
      %i[claude codex].each do |runtime|
        text = prepared(runtime, true)
        refute_includes text, "image-diff", runtime
        refute_includes text, STATIC_KEY, runtime
        refute_includes text, "STRAD_API_KEY", runtime
        assert_match(/catalog could not be read/, @processor.brokered_token_result.failures["image-diff"])
      end
    end
  end

  test "off, the catalog cannot be read: the broker step does nothing" do
    with_catalog(declared: true) do
      ServersConfig.stubs(:all!).raises(AirCatalogService::CatalogError, "down")
      assert_includes prepared(:claude, true), STATIC_KEY
    end
  end

  test "on, outside a turn start: the entry is removed and nothing reaches the static key" do
    turn_token_broker_on
    with_oauth_client_identity do
      @strad.create_grant!
      with_catalog(declared: true) do
        RUNTIMES.each_key do |runtime|
          text = prepared(runtime, false)
          refute_includes text, "image-diff", runtime
          refute_includes text, STATIC_KEY, runtime
        end
      end
    end
    assert_equal 0, McpBrokeredToken.count
  end

  # A session that lost all its servers reaches the baseline path with whatever
  # its last prepare left on the clone, possibly from before the switch went on.
  test "on, the baseline path removes a brokered entry left by an earlier prepare" do
    RUNTIMES.each_key do |runtime|
      fs = MockFileSystemAdapter.new
      turn_token_broker_off
      with_catalog(declared: true) { prepared(runtime, true, fs: fs) }
      @session.update_columns(mcp_servers: [])
      turn_token_broker_on
      with_catalog(declared: true) do
        text = prepared(runtime, true, fs: fs, baseline: true)
        refute_includes text, STATIC_KEY, runtime
        refute_includes text, "image-diff", runtime
      end
      @session.update_columns(mcp_servers: %w[image-diff])
    end
  end

  test "off, the baseline path leaves the entry as it always did" do
    fs = MockFileSystemAdapter.new
    with_catalog(declared: true) do
      prepared(:claude, true, fs: fs)
      @session.update_columns(mcp_servers: [])
      assert_includes prepared(:claude, true, fs: fs, baseline: true), STATIC_KEY
    end
  end

  # --- which entry is it? ---------------------------------------------------

  LOCAL_X = "@local/image-diff"
  OTHER_X = "@b/c/image-diff"

  test "on, two declaring entries contest the key and neither is selected by name: refused, never the static key" do
    turn_token_broker_on
    with_contested(local: true, other: true, selected: []) do
      text = prepared(:claude, true)
      refute_includes text, STATIC_KEY
      refute_includes text, "\"image-diff\""
      assert_match(/more than one catalog entry is called image-diff/, @processor.brokered_token_result.failures["image-diff"])
    end
  end

  test "on, the selected entry is undeclared and a same-named one declares: the selected entry keeps its own credential" do
    turn_token_broker_on
    with_oauth_client_identity do
      @strad.create_grant!
      with_contested(local: true, other: false, selected: [ OTHER_X ], config_url: "https://other.example.com/mcp") do
        text = prepared(:claude, true)
        assert_includes text, STATIC_KEY
        refute_includes text, "strad_oat_", "a token for the local entry must never reach the other entry's URL"
      end
      with_contested(local: false, other: true, selected: %w[image-diff]) do
        assert_includes prepared(:claude, true), STATIC_KEY
      end
    end
  end

  test "on, a token is never written onto a URL it is not for" do
    turn_token_broker_on
    with_oauth_client_identity do
      @strad.create_grant!
      with_catalog(declared: true) do
        text = prepared(:claude, true, url: "https://elsewhere.example.com/mcp")
        refute_includes text, "strad_oat_"
        refute_includes text, STATIC_KEY
        assert_match(/not the resource its token is for/, @processor.brokered_token_result.failures["image-diff"])
      end
    end
  end

  # --- declarations the broker cannot serve ---------------------------------

  test "on, a credential outside Authorization is a malformed declaration, and its variable never reaches the session" do
    turn_token_broker_on
    with_catalog(declared: true, headers: { "Authorization" => "Bearer ${STRAD_API_KEY}", "X-Api-Key" => "${STRAD_API_KEY}" }) do |server|
      assert_match(/carries a credential in X-Api-Key/, TokenBroker::Declaration.for(server).error)
      assert_empty server.session_variables
      assert_raises(McpServerEndpoint::UnresolvableError) { McpServerEndpoint.new(server).headers }
    end
  end

  test "on, a stdio entry that declares it is refused everywhere, the live bridge included" do
    turn_token_broker_on
    stub_mcp_catalog("image-diff" => { "type" => "stdio", "command" => "x", "env" => { "K" => "${STRAD_API_KEY}" },
                                       "brokered_auth" => { "scopes" => [ "slug:x" ], "authorization_server" => FakeStrad::ORIGIN } })
    server = ServersConfig.find("image-diff")

    assert_match(/not a remote server/, TokenBroker::Declaration.for(server).error)
    assert_empty server.session_variables
    assert_match(/not a remote server/, LiveConversations::CatalogServer.new(server).unavailable_reason)

    turn_token_broker_off
    assert_equal [ "STRAD_API_KEY" ], server.session_variables
    assert_nil LiveConversations::CatalogServer.new(server).unavailable_reason
  end

  # One predicate is only one predicate while nothing reads around it.
  test "nothing outside the broker and the catalog reader looks at the declaration" do
    allowed = %w[
      app/services/servers_config.rb app/services/token_broker.rb app/services/token_broker/declaration.rb
      app/controllers/token_broker_controller.rb app/services/connector_status_probe.rb
    ]
    readers = Dir[Rails.root.join("{app,lib}/**/*.{rb,erb,rake}")].select do |path|
      File.readlines(path).any? { |line| !line.match?(/\A\s*(#|<%#)/) && line.match?(/\bdeclares_brokered_auth\?|\.brokered_auth\b|Declaration\.for\b|\["brokered_auth"\]/) }
    end.map { |path| Pathname.new(path).relative_path_from(Rails.root).to_s }

    assert_empty readers - allowed, "these decide from the declaration instead of Server#brokered?"
  end

  test "on, a switch value nobody recognises: fails closed like on, not open like off" do
    ENV[TokenBroker::ENABLED_ENV] = "ture"
    assert_fails_closed(turn_on: false)
  end

  private

  # @param readiness [Boolean] whether configuration alone shows the problem. A
  #   strad or KMS outage does not: the row can read Ready, and minting still fails.
  def assert_fails_closed(declaration: { "scopes" => [ "slug:image-diff" ] }, turn_on: true, readiness: true)
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
      next unless readiness

      status = ConnectorStatusProbe.for("image-diff")
      assert_equal :broker_not_ready, status.state
      refute status.available?
      assert_nil status.broker_off_note
    end
  end

  # Two catalogs contributing `image-diff`, as AirCatalogService canonicalizes them.
  def with_contested(local:, other:, selected:, config_url: nil)
    mine = local ? brokered_strad_entry("image-diff") : static_strad_entry("image-diff")
    theirs = static_strad_entry("image-diff").merge("url" => "https://other.example.com/mcp")
    theirs["brokered_auth"] = { "scopes" => [ "slug:x" ] } if other
    stub_mcp_catalog(ArtifactIdentity.canonicalize(LOCAL_X => mine, OTHER_X => theirs))
    @session.update_columns(mcp_servers: selected)
    @config_url = config_url
    yield
  ensure
    @config_url = nil
    @session.update_columns(mcp_servers: %w[image-diff])
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
  #
  # Claude and Codex entries are rewritten every time, as `air prepare` does; Pi's
  # file is left as the previous call left it, because nothing rewrites that one.
  def prepared(runtime, mint, fs: MockFileSystemAdapter.new, baseline: false, url: nil)
    klass, path = RUNTIMES.fetch(runtime)
    full = File.join(@dir, path)
    url ||= @config_url || "#{FakeStrad::ORIGIN}/mcp?servers=image-diff"
    runtime = nil if baseline
    case runtime
    when :codex
      fs.write(full, TomlRB.dump("mcp_servers" => { "image-diff" => { "url" => url, "bearer_token_env_var" => "STRAD_API_KEY" } }))
    when :claude
      fs.write(full, JSON.pretty_generate("mcpServers" => { "image-diff" => {
        "type" => "http", "url" => url, "headers" => { "Authorization" => "Bearer ${STRAD_API_KEY}" }
      } }))
    end
    @processor = klass.new(session: @session.reload, working_directory: @dir, file_system: fs)
    @processor.mint_brokered_tokens = mint
    baseline ? @processor.ensure_baseline! : @processor.post_process!
    fs.read(full)
  end
end
