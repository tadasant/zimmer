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

  # Everything a brokered entry may hold once every other step has run.
  BROKERED_ENTRY_KEYS = {
    claude: %w[type url headers], codex: %w[url http_headers startup_timeout_sec], pi: %w[type url headers requestTimeoutMs]
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

  # Through AirPrepareService, with an AIR that does what its adapters do: it writes
  # the entries the command line names, removes the ones it wrote before and is no
  # longer given, and touches nothing else. So a broker that kept an entry from AIR
  # after it was turned off, or left its own entry behind, shows up here.
  RUNTIMES.each_key do |runtime|
    test "on then off, #{runtime}: the session's next prepare gives the undeclared entry's config again" do
      air = FakeAir.new(runtime, File.join(@dir, RUNTIMES[runtime].last))
      today = with_catalog(declared: false) { prepare_with(air) }

      air = FakeAir.new(runtime, File.join(@dir, RUNTIMES[runtime].last))
      with_grant do
        on = prepare_with(air)
        assert_includes on, "strad_oat_", runtime
        refute_includes on, "STRAD_API_KEY", runtime
        assert_equal [ "image-diff" ], @session.reload.metadata[RuntimeConfigPostProcessor::BROKERED_ENTRIES_KEY]

        turn_token_broker_off
        off = prepare_with(air)
        refute_includes off, "strad_oat_", runtime
        # Content, not bytes: a rewritten entry can move within its table.
        assert_equal parsed(runtime, today), parsed(runtime, off)
        refute @session.reload.metadata.key?(RuntimeConfigPostProcessor::BROKERED_ENTRIES_KEY), "the record is cleared once nothing of the broker's is left"

        turn_token_broker_on
        again = prepare_with(air)
        assert_includes again, "strad_oat_", runtime
        refute_includes again, STATIC_KEY, runtime
        refute_includes again, "STRAD_API_KEY", runtime
        assert_not_equal on, again
      end
    end

    # The path Hans was on: never on, catalog already declaring.
    test "never on, #{runtime}: through the whole prepare, a declaring entry's config is byte-identical to an undeclared one's" do
      path = File.join(@dir, RUNTIMES[runtime].last)
      undeclared = with_catalog(declared: false) { prepare_with(FakeAir.new(runtime, path)) }
      declared = with_catalog(declared: true) { prepare_with(FakeAir.new(runtime, path)) }
      assert_equal undeclared, declared
      refute @session.reload.metadata.key?(RuntimeConfigPostProcessor::BROKERED_ENTRIES_KEY)
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
      client = TokenBroker::Client.new
      client.stubs(:exchange).raises(TokenBroker::Client::Error, "HTTP 503")
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
  test "on, the catalog cannot be read: every entry is dropped with a cause, none given its static key" do
    turn_token_broker_on
    with_catalog(declared: true) do
      ServersConfig.stubs(:all).returns([])
      ServersConfig.stubs(:all!).raises(AirCatalogService::CatalogError, "down")
      %i[claude codex].each do |runtime|
        text = prepared(runtime, true, entry: { "command" => "x", "env" => { "K" => "${STRAD_API_KEY}" } })
        refute_includes text, "image-diff", "#{runtime}, a stdio entry"
      end
      RUNTIMES.each_key do |runtime|
        fs = MockFileSystemAdapter.new
        write_entries(runtime, fs, "image-diff" => { "url" => catalog_url, "headers" => { "Authorization" => "Bearer ${STRAD_API_KEY}" } })
        text = prepared(runtime, true, fs: fs, keep: true)
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

  test "on with a grant, the baseline path mints nothing" do
    with_grant do
      RUNTIMES.each_key { |runtime| refute_includes prepared(runtime, true, baseline: true), "strad_oat_", runtime }
    end
    assert_equal 0, McpBrokeredToken.count
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

  test "on, two declaring entries contest the key and the session selected neither: removed, never the static key" do
    turn_token_broker_on
    with_contested(local: true, other: true, selected: []) do
      text = prepared(:claude, true)
      refute_includes text, STATIC_KEY
      refute_includes text, "\"image-diff\""
    end
  end

  test "on, a stored name that could be two entries, one of them brokered: refused with the cause" do
    turn_token_broker_on
    stub_mcp_catalog(ArtifactIdentity.canonicalize("@a/c/image-diff" => brokered_strad_entry("image-diff"), OTHER_X => static_strad_entry("image-diff")))
    RUNTIMES.each_key do |runtime|
      text = prepared(runtime, true)
      refute_includes text, STATIC_KEY, runtime
      refute_includes text, "STRAD_API_KEY", runtime
      assert_match(/more than one catalog entry is called image-diff/, @processor.brokered_token_result.failures["image-diff"], runtime)
    end
  end

  test "on, the session selected two entries that share a key, one brokered: refused, not the brokered one by default" do
    turn_token_broker_on
    with_oauth_client_identity do
      @strad.create_grant!
      with_contested(local: true, other: false, selected: [ "image-diff", OTHER_X ]) do
        text = prepared(:claude, true)
        refute_includes text, STATIC_KEY
        refute_includes text, "strad_oat_"
        assert_match(/more than one catalog entry/, @processor.brokered_token_result.failures["image-diff"])
      end
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
        assert_empty TokenBroker.brokered_among([ OTHER_X ]), "a contested name must not resolve to whichever entry declares"
      end
      with_contested(local: false, other: true, selected: %w[image-diff]) do
        assert_includes prepared(:claude, true), STATIC_KEY
        assert_empty TokenBroker.brokered_among(%w[image-diff])
      end
    end
  end

  # --- nothing already on disk survives beside the token ----------------------

  test "on, whatever URL the file names, the token goes to the catalog's URL" do
    with_grant do
      [ "https://elsewhere.example.com/mcp", "#{FakeStrad::ORIGIN}/other", "#{FakeStrad::ORIGIN}/mcp/../evil",
        "https://user@strad.example.com/mcp?servers=image-diff", "HTTPS://strad.example.com:8443/mcp" ].each do |url|
        text = prepared(:claude, true, url: url)
        refute_includes text, url
        entry = parsed(:claude, text).fetch("mcpServers").fetch("image-diff")
        assert_equal catalog_url, entry["url"]
        assert_match(/\ABearer strad_oat_/, entry.dig("headers", "Authorization"))
      end
    end
  end

  test "on, no other credential field on the file's entry survives, on any runtime" do
    poison = {
      claude: { "headersHelper" => "x", "headers" => { "X-Api-Key" => "${STRAD_API_KEY}", "authorization" => "Bearer ${STRAD_API_KEY}" }, "env" => { "K" => "${STRAD_API_KEY}" } },
      pi: { "auth" => "bearer", "bearerTokenEnv" => "STRAD_API_KEY", "bearerToken" => "${STRAD_API_KEY}", "requestHeadersCommand" => "x",
            "headers" => { "X-Api-Key" => "${STRAD_API_KEY}" } },
      codex: { "bearer_token_env_var" => "STRAD_API_KEY", "env_http_headers" => { "X-Strad" => "STRAD_API_KEY", "Authorization" => "STRAD_API_KEY" },
               "http_headers" => { "X-Api-Key" => "${STRAD_API_KEY}" } }
    }
    with_grant do
      poison.each do |runtime, extra|
        text = prepared(runtime, true, entry: { "url" => catalog_url }.merge(extra))
        refute_includes text, STATIC_KEY, runtime
        refute_includes text, "STRAD_API_KEY", runtime
        assert_empty server_table(runtime, text).fetch("image-diff").keys - BROKERED_ENTRY_KEYS.fetch(runtime), runtime
      end
    end
  end

  test "on, an entry whose headers are not a table costs nothing" do
    with_grant do
      assert_includes prepared(:claude, true, entry: { "url" => catalog_url, "headers" => "nonsense" }), "strad_oat_"
    end
  end

  # A child's scope is the session's servers, whatever else a file names.
  test "on, a brokered entry the session did not select is removed, and nothing is minted for it" do
    RUNTIMES.each_key do |runtime|
      with_grant(extra: { "svg-tracer" => brokered_strad_entry("svg-tracer") }) do
        McpBrokeredToken.delete_all
        fs = MockFileSystemAdapter.new
        write_entries(runtime, fs, "svg-tracer" => { "url" => "#{FakeStrad::ORIGIN}/mcp?servers=svg-tracer" })
        table = server_table(runtime, prepared(runtime, true, fs: fs, keep: true))

        scopes = McpBrokeredToken.pluck(:scope).flat_map(&:split).uniq
        refute_includes scopes, "slug:svg-tracer", "#{runtime}: a child reaches only the servers the session selected"
        refute table.key?("svg-tracer"), runtime
        assert table.key?("image-diff"), runtime
        assert_equal %w[slug:image-diff], scopes, runtime
        refute @processor.brokered_token_result.failures.key?("svg-tracer"), "not selected, so not a degradation"
      end
      McpBrokerGrant.destroy_all
    end
  end

  test "on, an entry keeps its catalog headers that hold no credential, its transport, and Zimmer's own approval header" do
    with_grant(entry: brokered_strad_entry("image-diff").merge("type" => "sse",
      "headers" => { "authorization" => "Bearer ${STRAD_API_KEY}", "X-Plain" => "1", "x-elicitation-url" => "${ELICITATION_REQUEST_URL}" })) do
      entry = server_table(:claude, prepared(:claude, true)).fetch("image-diff")
      assert_equal "sse", entry["type"]
      assert_equal %w[Authorization X-Plain], entry["headers"].keys.sort
    end
  end

  test "on, Zimmer's own injected entries are never touched by the broker step" do
    turn_token_broker_on
    stub_mcp_catalog("zimmer-self-session" => brokered_strad_entry("zimmer-self-session"), "image-diff" => static_strad_entry("image-diff"))
    assert server_table(:claude, prepared(:claude, true)).key?("zimmer-self-session")
  end

  test "AIR is given no brokered entry while on, and every entry while off" do
    @session.update_columns(mcp_servers: %w[image-diff granola])
    stub_mcp_catalog("image-diff" => brokered_strad_entry("image-diff"), "granola" => static_strad_entry("granola"))
    service = AirPrepareService.new(session: @session, working_directory: @dir)
    service.stubs(:catch_up_catalog_cache!)
    commands = []
    service.stubs(:run_air_prepare_command!).with { |cmd, _| commands << cmd }

    service.send(:run_air_prepare!)
    turn_token_broker_on
    service.send(:run_air_prepare!)

    assert_equal %w[granola image-diff], commands.first.each_cons(2).filter_map { |flag, id| id if flag == "--mcp-server" }.sort
    assert_equal %w[granola], commands.last.each_cons(2).filter_map { |flag, id| id if flag == "--mcp-server" }
  end

  test "on, a template session that was never saved can be prepared" do
    template = Session.new(mcp_servers: %w[image-diff], agent_runtime: "claude_code", metadata: {})
    with_grant do
      fs = MockFileSystemAdapter.new
      write_entries(:claude, fs, "image-diff" => { "url" => catalog_url, "headers" => { "Authorization" => "Bearer ${STRAD_API_KEY}" } })
      processor = ClaudeMcpConfigPostProcessor.new(session: template, working_directory: @dir, file_system: fs)
      processor.post_process!
      refute_includes fs.read(File.join(@dir, RUNTIMES[:claude].last)), STATIC_KEY
    end
  end

  # --- one decision everywhere: the reused clone, the grant, the fork ---------

  test "on, the reused-clone path re-prepares when the catalog cannot be read, rather than trusting the file" do
    turn_token_broker_on
    ServersConfig.stubs(:all!).raises(AirCatalogService::CatalogError, "down")
    ServersConfig.stubs(:all).returns([])
    expect_reprepare { remint }
  end

  test "on, the reused-clone path re-prepares when only an unselected or contested entry is brokered" do
    turn_token_broker_on
    stub_mcp_catalog("image-diff" => static_strad_entry("image-diff"), "svg-tracer" => brokered_strad_entry("svg-tracer"))
    expect_reprepare { remint }
  end

  test "the reused-clone path mints for a turn, and not for a clone-only job" do
    turn_token_broker_on
    with_catalog(declared: true) do
      expect_reprepare(mint: false) { remint(mint: false) }
      expect_reprepare(mint: true) { remint(mint: true) }
    end
  end

  test "reconnecting to a different resource ends the backend tokens minted for the old one" do
    with_grant do |server|
      old = TokenBroker.backend_token(server)
      flow = McpOauthPendingFlow.new(broker_authorization_server: FakeStrad::ORIGIN, token_endpoint: FakeStrad::TOKEN_ENDPOINT,
        resource: "#{FakeStrad::ORIGIN}/mcp2", client_id: OauthClientIdentity.client_id, server_url: "#{FakeStrad::ORIGIN}/mcp2", mcp_server_config: {})
      tokens = { "access_token" => "strad_oat_parent2", "refresh_token" => "strad_ort_parent2", "expires_in" => 3600 }
      McpBrokerGrant.store_consent!(flow, tokens)

      stub_mcp_catalog("image-diff" => brokered_strad_entry("image-diff").merge("url" => "#{FakeStrad::ORIGIN}/mcp2"))
      assert_not_equal old, TokenBroker.backend_token(ServersConfig.find("image-diff"))
      assert_not_equal "live", McpBrokeredToken.order(:id).first.state
    end
  end

  test "reconnecting to the same resource keeps them" do
    with_grant do |server|
      old = TokenBroker.backend_token(server)
      grant = McpBrokerGrant.sole
      flow = McpOauthPendingFlow.new(broker_authorization_server: FakeStrad::ORIGIN, token_endpoint: FakeStrad::TOKEN_ENDPOINT,
        resource: grant.resource, client_id: grant.client_id, server_url: grant.resource, mcp_server_config: {})
      McpBrokerGrant.store_consent!(flow, "access_token" => "strad_oat_p2", "refresh_token" => "strad_ort_p2", "expires_in" => 3600)
      assert_equal old, TokenBroker.backend_token(server)
    end
  end

  test "one entry's backend token is never reused for another's scope" do
    with_grant(extra: { "svg-tracer" => brokered_strad_entry("svg-tracer") }) do |server|
      assert_not_equal TokenBroker.backend_token(server), TokenBroker.backend_token(ServersConfig.find("svg-tracer"))
    end
  end

  # --- on, then off: the leftovers the review found -----------------------------

  test "on then off: an entry the broker wrote and the session has since dropped is removed" do
    RUNTIMES.each_key do |runtime|
      fs = MockFileSystemAdapter.new
      with_grant { prepared(runtime, true, fs: fs) }
      turn_token_broker_off
      @session.update_columns(mcp_servers: %w[other])
      stub_mcp_catalog("image-diff" => brokered_strad_entry("image-diff"), "other" => static_strad_entry("other"))
      refute_includes prepared(runtime, true, fs: fs, keep: true), "strad_oat_", runtime
      refute @session.reload.metadata.key?(RuntimeConfigPostProcessor::BROKERED_ENTRIES_KEY), runtime
      @session.update_columns(mcp_servers: %w[image-diff])
      McpBrokerGrant.destroy_all
    end
  end

  test "on then off: the baseline path removes the revoked token and clears the record" do
    RUNTIMES.each_key do |runtime|
      fs = MockFileSystemAdapter.new
      with_grant { prepared(runtime, true, fs: fs) }
      turn_token_broker_off
      @session.update_columns(mcp_servers: [])
      refute_includes prepared(runtime, true, fs: fs, baseline: true), "strad_oat_", runtime
      refute @session.reload.metadata.key?(RuntimeConfigPostProcessor::BROKERED_ENTRIES_KEY), runtime
      @session.update_columns(mcp_servers: %w[image-diff])
      McpBrokerGrant.destroy_all
    end
  end

  test "the record grows across prepares, so nothing an earlier one touched is forgotten" do
    fs = MockFileSystemAdapter.new
    with_grant { prepared(:pi, true, fs: fs) }
    @session.update_columns(mcp_servers: %w[svg-tracer])
    with_grant(entry: static_strad_entry("image-diff"), extra: { "svg-tracer" => brokered_strad_entry("svg-tracer") }) { prepared(:pi, true, fs: fs) }
    assert_equal %w[image-diff svg-tracer], @session.reload.metadata[RuntimeConfigPostProcessor::BROKERED_ENTRIES_KEY]
  end

  test "the baseline path writes the file when all it did was remove a brokered entry" do
    fs = MockFileSystemAdapter.new
    with_catalog(declared: true) { prepared(:claude, true, fs: fs) }
    @session.update_columns(mcp_servers: [])
    turn_token_broker_on
    with_catalog(declared: true) do
      ClaudeMcpConfigPostProcessor.any_instance.stubs(:inject_self_session_server!)
      refute_includes prepared(:claude, true, fs: fs, baseline: true), STATIC_KEY
    end
  end

  test "a refusal is recorded, so a retry after the switch goes off puts the entry back" do
    turn_token_broker_on
    stub_mcp_catalog(ArtifactIdentity.canonicalize("@a/c/image-diff" => brokered_strad_entry("image-diff"), OTHER_X => static_strad_entry("image-diff")))
    prepared(:claude, true)
    assert_equal [ "image-diff" ], @session.reload.metadata[RuntimeConfigPostProcessor::BROKERED_ENTRIES_KEY]
    turn_token_broker_off
    expect_reprepare { remint }
  end

  # --- what the off switch must not take with it -------------------------------

  test "on then off: a server Zimmer injects is never removed, even after a turn on which the catalog could not be read" do
    %i[claude codex].each do |runtime|
      [ true, false ].each do |baseline|
        fs = MockFileSystemAdapter.new
        @session.update_columns(mcp_servers: %w[image-diff], custom_metadata: { "injected_mcp_servers" => [ "zimmer" ] })
        turn_token_broker_on
        with_catalog(declared: true) do
          write_entries(runtime, fs, "zimmer" => { "url" => "http://localhost:3000/mcp" }, "image-diff" => { "url" => catalog_url })
          ServersConfig.stubs(:all!).raises(AirCatalogService::CatalogError, "down")
          table = server_table(runtime, prepared(runtime, true, fs: fs, keep: true))
          assert table.key?("zimmer"), "#{runtime}: Zimmer's own server survives an unreadable catalog"
          refute table.key?("image-diff"), runtime
          ServersConfig.unstub(:all!)
        end
        @session.merge_metadata!(RuntimeConfigPostProcessor::BROKERED_ENTRIES_KEY => %w[image-diff zimmer])
        @session.update_columns(mcp_servers: []) if baseline
        turn_token_broker_off
        with_catalog(declared: true) do
          assert server_table(runtime, prepared(runtime, true, fs: fs, keep: true, baseline: baseline)).key?("zimmer"), "#{runtime} baseline=#{baseline}"
        end
      end
    end
  end

  test "on then off: an entry the repository wrote under an unselected brokered name is not deleted once off" do
    RUNTIMES.each_key do |runtime|
      fs = MockFileSystemAdapter.new
      with_grant(extra: { "svg-tracer" => brokered_strad_entry("svg-tracer") }) do
        write_entries(runtime, fs, "svg-tracer" => { "url" => "https://repo.example.com/mcp" })
        prepared(runtime, true, fs: fs, keep: true)
        turn_token_broker_off
        fresh = MockFileSystemAdapter.new
        write_entries(runtime, fresh, "svg-tracer" => { "url" => "https://repo.example.com/mcp" })
        assert_includes prepared(runtime, true, fs: fresh, keep: true), "https://repo.example.com/mcp", runtime
      end
      McpBrokerGrant.destroy_all
    end
  end

  test "on then off: a selected entry AIR was not given back is removed, not kept with its revoked token" do
    %i[claude codex].each do |runtime|
      fs = MockFileSystemAdapter.new
      with_grant { assert_includes prepared(runtime, true, fs: fs), "strad_oat_" }
      turn_token_broker_off
      stub_mcp_catalog("other" => static_strad_entry("other"))
      refute_includes prepared(runtime, true, fs: fs, keep: true), "strad_oat_", runtime
      McpBrokerGrant.destroy_all
    end
  end

  test "pi, on then off: an entry is not protected by another catalog's entry with the same short id" do
    fs = MockFileSystemAdapter.new
    with_grant { assert_includes prepared(:pi, true, fs: fs), "strad_oat_" }
    turn_token_broker_off
    with_contested(local: false, other: false, selected: [ OTHER_X ]) { refute_includes prepared(:pi, true, fs: fs), "strad_oat_" }
  end

  test "on then off: a server degraded because its child token was rejected mid-turn is no longer recorded as lost" do
    fs = MockFileSystemAdapter.new
    with_grant do
      prepared(:claude, true, fs: fs)
      @session.reload.merge_metadata!("mcp_degraded_servers" => [ { "name" => "image-diff", "error" => "HTTP 401" }, { "name" => "granola", "error" => "timeout" } ])
      turn_token_broker_off
      prepared(:claude, true, fs: fs)
    end
    assert_equal %w[granola], @session.reload.degraded_mcp_servers.map { |entry| entry["name"] }
  end

  test "a restart from scratch forgets the record with the clone it was about" do
    assert_includes Session::SETUP_ARTIFACT_KEYS, RuntimeConfigPostProcessor::BROKERED_ENTRIES_KEY
  end

  test "a resource keeps its userinfo, port and path, so it never equals a different one" do
    base = TokenBroker.normalize_resource("https://strad.example.com/mcp")
    %w[https://user@strad.example.com/mcp https://strad.example.com:8443/mcp https://strad.example.com/mcp2 https://strad.example.com/mcp/x
       https://strad.example.com.evil.example/mcp http://strad.example.com/mcp].each { |url| assert_not_equal base, TokenBroker.normalize_resource(url), url }
    assert_equal base, TokenBroker.normalize_resource("https://strad.example.com/mcp/?servers=x#y")
  end

  test "on then off: a refused entry, not only a served one, is put back on Pi" do
    fs = MockFileSystemAdapter.new
    turn_token_broker_on
    with_catalog(declared: true) { refute_includes prepared(:pi, true, fs: fs), "image-diff" }
    assert_equal [ "image-diff" ], @session.reload.metadata[RuntimeConfigPostProcessor::BROKERED_ENTRIES_KEY]
    turn_token_broker_off
    with_catalog(declared: true) { assert_includes prepared(:pi, true, fs: fs), STATIC_KEY }
  end

  test "on -> off -> on: the entry is brokered again with a new token, and only one is live" do
    RUNTIMES.each_key do |runtime|
      fs = MockFileSystemAdapter.new
      with_grant do
        first = prepared(runtime, true, fs: fs)
        turn_token_broker_off
        assert_includes prepared(runtime, true, fs: fs), (runtime == :codex ? "STRAD_API_KEY" : STATIC_KEY)
        turn_token_broker_on
        third = prepared(runtime, true, fs: fs)
        refute_includes third, STATIC_KEY, runtime
        refute_includes third, "STRAD_API_KEY", runtime
        assert_not_equal first, third
        assert_equal 1, McpBrokeredToken.for_sessions.live.count, runtime
      end
      McpBrokeredToken.delete_all
      McpBrokerGrant.destroy_all
    end
  end

  test "pi: a recorded entry the catalog no longer has, or cannot express, is dropped rather than kept with its old token" do
    [ {}, { "image-diff" => { "type" => "streamable-http", "brokered_auth" => { "scopes" => [ "slug:x" ] } } } ].each do |catalog|
      fs = MockFileSystemAdapter.new
      with_grant { prepared(:pi, true, fs: fs) }
      turn_token_broker_off
      stub_mcp_catalog(catalog)
      refute_includes prepared(:pi, true, fs: fs), "strad_oat_"
      McpBrokerGrant.destroy_all
    end
  end

  test "a degradation that is still true is kept, and one whose cause ended is forgotten" do
    broker = ->(name) { { "name" => name, "error" => "token_broker_unavailable", "reason" => "x", "degraded_at" => "2020-01-01" } }
    @session.merge_metadata!("mcp_degraded_servers" => [ broker["image-diff"], broker["svg-tracer"] ])
    result = TokenBroker::MintResult.new(tokens: {}, failures: { "image-diff" => "still no grant" })
    job = AgentSessionJob.new

    job.send(:forget_resolved_broker_degradations, @session, result)

    assert_equal %w[image-diff], @session.reload.degraded_mcp_servers.map { |e| e["name"] }
  end

  # --- declarations the broker cannot serve ---------------------------------

  test "on, a credential outside Authorization is a malformed declaration, and its variable never reaches the session" do
    turn_token_broker_on
    with_catalog(declared: true, headers: { "Authorization" => "Bearer ${STRAD_API_KEY}", "X-Api-Key" => "${STRAD_API_KEY}" }) do |server|
      assert_match(/carries a credential or a variable in X-Api-Key/, TokenBroker::Declaration.for(server).error)
      assert_empty server.session_variables
      assert_raises(McpServerEndpoint::UnresolvableError) { McpServerEndpoint.new(server).headers }
    end
  end

  test "on, any variable outside Authorization is malformed, whatever its header is called" do
    turn_token_broker_on
    %w[Cookie X-Strad-Key X-Access-Key X-Subscription-Key X-Org].each do |header|
      with_catalog(declared: true, headers: { "Authorization" => "Bearer ${STRAD_API_KEY}", header => "k=${STRAD_API_KEY}" }) do |server|
        assert_match(/#{header}/, TokenBroker::Declaration.for(server).error.to_s)
        assert_empty server.session_variables
        RUNTIMES.each_key { |runtime| refute_includes prepared(runtime, true), STATIC_KEY, "#{header} #{runtime}" }
      end
    end
  end

  test "on, a remote entry with env or args, or a url that is not a resource, is malformed" do
    turn_token_broker_on
    base = brokered_strad_entry("image-diff")
    [ base.merge("env" => { "K" => "${STRAD_API_KEY}" }), base.merge("args" => [ "${STRAD_API_KEY}" ]), base.merge("url" => "https://${HOST}/mcp"),
      base.merge("url" => "https://${HOST}/mcp", "brokered_auth" => { "scopes" => [ "slug:x" ], "authorization_server" => FakeStrad::ORIGIN }) ].each do |entry|
      stub_mcp_catalog("image-diff" => entry)
      server = ServersConfig.find("image-diff")
      assert TokenBroker::Declaration.for(server).error.present?, entry.inspect
      assert_empty server.session_variables
    end
  end

  test "on, a lower-case authorization header is replaced like any other" do
    with_grant(entry: static_strad_entry("image-diff").merge("headers" => { "authorization" => "Bearer ${STRAD_API_KEY}" }, "brokered_auth" => { "scopes" => [ "slug:image-diff" ] })) do |server|
      assert_empty server.session_variables
      assert_equal %w[Authorization], server_table(:claude, prepared(:claude, true)).dig("image-diff", "headers").keys
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

  def catalog_url = "#{FakeStrad::ORIGIN}/mcp?servers=image-diff"

  # The broker on, the identity configured, a usable grant, and one declaring entry.
  def with_grant(entry: brokered_strad_entry("image-diff"), extra: {})
    turn_token_broker_on
    with_oauth_client_identity do
      @strad.create_grant! unless McpBrokerGrant.exists?
      stub_mcp_catalog({ "image-diff" => entry }.merge(extra))
      yield ServersConfig.find("image-diff")
    end
  end

  class FakeAir
    attr_reader :fs, :runtime

    def initialize(runtime, path)
      @runtime = runtime
      @path = path
      @fs = MockFileSystemAdapter.new
      @managed = []
    end

    def run(cmd)
      return if @runtime == :pi # its adapter writes no MCP config at all

      key = @runtime == :codex ? "mcp_servers" : "mcpServers"
      config = @fs.exists?(@path) ? (@runtime == :codex ? TomlRB.parse(@fs.read(@path)) : JSON.parse(@fs.read(@path))) : {}
      named = cmd.each_cons(2).filter_map { |flag, id| id if flag == "--mcp-server" }
      table = (config[key] || {}).except(*(@managed - named))
      named.each do |id|
        url = "#{FakeStrad::ORIGIN}/mcp?servers=#{id}"
        table[id] = @runtime == :codex ? { "url" => url, "bearer_token_env_var" => "STRAD_API_KEY" } :
          { "type" => "http", "url" => url, "headers" => { "Authorization" => "Bearer ${STRAD_API_KEY}" } }
      end
      @managed = named
      config[key] = table
      @fs.write(@path, @runtime == :codex ? TomlRB.dump(config) : JSON.generate(config))
    end

    def read = @fs.read(@path)
  end

  # One turn's real AirPrepareService#prepare!, with only what is not the MCP
  # config stubbed out.
  def prepare_with(air)
    runtime = air.runtime
    session = @session.reload
    session.stubs(:runtime).returns(RuntimeRegistry.for({ claude: "claude_code", codex: "codex", pi: "pi" }.fetch(runtime)))
    service = AirPrepareService.new(session: session, working_directory: @dir, file_system: air.fs, mint_brokered_tokens: true)
    %i[guard_injected_files! write_env_file! write_system_prompt_file! catch_up_catalog_cache!].each { |step| service.stubs(step) }
    service.stubs(:artifact_bridge).returns(stub(write!: true))
    service.define_singleton_method(:run_air_prepare_command!) { |cmd, _env| air.run(cmd) }
    service.prepare!
    air.read
  end

  def remint(mint: true)
    AgentSessionJob.new.send(:remint_brokered_tokens_for_reused_clone, @session, @dir, LogBuffer.new(@session), mint: mint)
  end

  def expect_reprepare(mint: true)
    prepare = stub(prepare!: true, injected_mcp_servers: [], brokered_token_result: TokenBroker::MintResult.empty)
    AirPrepareService.expects(:new).with { |**kw| kw[:mint_brokered_tokens] == mint }.returns(prepare)
    assert_equal :reprepared, yield
  end

  def parsed(runtime, text) = runtime == :codex ? TomlRB.parse(text) : JSON.parse(text)

  def server_table(runtime, text) = parsed(runtime, text).fetch(runtime == :codex ? "mcp_servers" : "mcpServers")

  def write_entries(runtime, fs, entries)
    full = File.join(@dir, RUNTIMES.fetch(runtime).last)
    fs.write(full, runtime == :codex ? TomlRB.dump("mcp_servers" => entries) : JSON.generate("mcpServers" => entries))
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
  # `keep` leaves the others too, and `entry` is what to find in the file instead.
  def prepared(runtime, mint, fs: MockFileSystemAdapter.new, baseline: false, url: nil, entry: nil, keep: false)
    klass, path = RUNTIMES.fetch(runtime)
    full = File.join(@dir, path)
    url ||= @config_url || catalog_url
    if entry
      write_entries(runtime, fs, "image-diff" => entry)
    elsif !baseline && !keep
      write_entries(:claude, fs, "image-diff" => { "type" => "http", "url" => url, "headers" => { "Authorization" => "Bearer ${STRAD_API_KEY}" } }) if runtime == :claude
      write_entries(:codex, fs, "image-diff" => { "url" => url, "bearer_token_env_var" => "STRAD_API_KEY" }) if runtime == :codex
    end
    @processor = klass.new(session: @session.reload, working_directory: @dir, file_system: fs)
    @processor.mint_brokered_tokens = mint
    baseline ? @processor.ensure_baseline! : @processor.post_process!
    fs.read(full)
  end
end
