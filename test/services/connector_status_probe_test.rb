# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"
require "support/fake_parameter_store"

class ConnectorStatusProbeTest < ActiveSupport::TestCase
  # A catalog entry shaped like the strad-hosted MCP servers Zimmer connects to:
  # a remote server whose only credential is a static bearer header sourced from
  # a ${VAR}. This is the motivating "missing configuration" case.
  SECRETS_SERVICE_ACCOUNT = {
    "title" => "Secrets Service Account",
    "description" => "Strad-hosted secrets MCP server.",
    "type" => "streamable-http",
    "url" => "https://strad.example.com/mcp?servers=secrets",
    "headers" => { "Authorization" => "Bearer ${STRAD_API_KEY}" }
  }.freeze

  # A remote server whose credential is a static header under a VENDOR-SPECIFIC
  # name — Google's `X-Goog-Api-Key` rather than the generic `X-API-Key`. Auth is
  # every bit as static as SECRETS_SERVICE_ACCOUNT's bearer header; only the
  # spelling differs, and the spelling must not decide whether OAuth applies.
  VENDOR_HEADER_SERVER = {
    "title" => "Google Maps",
    "description" => "Google Maps Grounding Lite MCP server.",
    "type" => "streamable-http",
    "url" => "https://mapstools.example.com/mcp",
    "headers" => { "X-Goog-Api-Key" => "${GOOGLE_MAPS_API_KEY}" }
  }.freeze

  OAUTH_SERVER = {
    "title" => "Notion",
    "description" => "Hosted Notion MCP server.",
    "type" => "streamable-http",
    "url" => "https://mcp.notion.example.com/mcp"
  }.freeze

  STDIO_NO_SECRETS = {
    "title" => "Context7",
    "description" => "Docs lookup.",
    "type" => "stdio",
    "command" => "npx",
    "args" => [ "-y", "@upstash/context7-mcp@latest" ]
  }.freeze

  STDIO_WITH_SECRET = {
    "title" => "Slack Workspace",
    "description" => "Slack workspace MCP server.",
    "type" => "stdio",
    "command" => "npx",
    "args" => [ "-y", "slack-workspace-mcp-server@latest" ],
    "env" => { "SLACK_BOT_TOKEN" => "${SLACK_BOT_TOKEN}" }
  }.freeze

  def server(name, config)
    ServersConfig::Server.new(name, config)
  end

  # Stubs the catalog so the probe's internal ServersConfig lookups (credential
  # key computation, oauth-capability) see the entry under test rather than the
  # real mcp.json.
  def with_catalog(name, config)
    AirCatalogService.stubs(:entries_for).returns({})
    AirCatalogService.stubs(:entries_for).with(:mcp).returns({ name => config })
    yield
  end

  ABSENT = SecretsInterpolator::Resolution.new(state: :absent)
  FOUND = SecretsInterpolator::Resolution.new(state: :found, source: "a stubbed provider")

  def unavailable(message)
    SecretsInterpolator::Resolution.new(state: :unavailable,
      error: ParameterStore::StoreError.new(message, 503))
  end

  def probe(name, config, resolvable: [], unavailable_vars: {})
    interpolator = SecretsInterpolator.new
    interpolator.stubs(:resolution).returns(ABSENT)
    resolvable.each { |var| interpolator.stubs(:resolution).with(var).returns(FOUND) }
    unavailable_vars.each { |var, message| interpolator.stubs(:resolution).with(var).returns(unavailable(message)) }

    with_catalog(name, config) do
      ConnectorStatusProbe.new(server(name, config), interpolator: interpolator).call
    end
  end

  # --- missing configuration -------------------------------------------------

  test "reports missing configuration when a required header variable is unset" do
    status = probe("secrets-service-account", SECRETS_SERVICE_ACCOUNT)

    assert_equal :missing_configuration, status.state
    assert_equal [ "STRAD_API_KEY" ], status.missing_variables
    assert_equal "Missing configuration", status.label
    assert_match "STRAD_API_KEY", status.summary
  end

  test "missing configuration help text names the variable, the file and the command" do
    status = probe("secrets-service-account", SECRETS_SERVICE_ACCOUNT)
    instruction = status.instructions.sole

    assert_equal "STRAD_API_KEY", instruction[:variable]
    assert_equal SecretsLocation.credentials_path, instruction[:path]
    assert_equal SecretsLocation.edit_command, instruction[:command]
    assert_match "mcp_secrets:", instruction[:snippet]
    assert_match "STRAD_API_KEY", instruction[:snippet]
    assert_match "STRAD_API_KEY", instruction[:headline]
  end

  test "help text carries a placeholder, never the real value" do
    status = probe("slack-workspace", STDIO_WITH_SECRET)

    assert_equal :missing_configuration, status.state
    assert_match "<the-secret-value>", status.instructions.sole[:snippet]
  end

  test "a set secret's value never appears in any status text" do
    secret = "xoxb-super-secret-value"
    SecretProviders.reset!
    SecretsLoader.stubs(:exists?).returns(false)
    SecretsLoader.stubs(:get).returns(nil)
    SecretsLoader.stubs(:exists?).with("SLACK_BOT_TOKEN").returns(true)
    SecretsLoader.stubs(:get).with("SLACK_BOT_TOKEN").returns(secret)

    status = with_catalog("slack-workspace", STDIO_WITH_SECRET) do
      ConnectorStatusProbe.new(server("slack-workspace", STDIO_WITH_SECRET)).call
    end

    assert_equal :ready, status.state, "a resolvable required variable makes the server ready"
    rendered = [ status.label, status.summary, status.instructions.to_s ].join(" ")
    assert_no_match(/#{Regexp.escape(secret)}/, rendered)
    assert_match "SLACK_BOT_TOKEN", status.summary
  end

  test "reports every missing variable, not just the first" do
    config = STDIO_WITH_SECRET.merge("env" => { "A" => "${ALPHA}", "B" => "${BETA}" })
    status = probe("multi", config)

    assert_equal :missing_configuration, status.state
    assert_equal %w[ALPHA BETA], status.missing_variables.sort
    assert_equal 2, status.instructions.size
  end

  test "a variable with a default is not treated as missing" do
    config = STDIO_NO_SECRETS.merge("env" => { "MODE" => "${MODE:-headless}" })
    status = probe("defaulted", config)

    assert_equal :no_credential_required, status.state
  end

  # --- ready -----------------------------------------------------------------

  test "a static-header server whose variable resolves is ready" do
    status = probe("secrets-service-account", SECRETS_SERVICE_ACCOUNT, resolvable: [ "STRAD_API_KEY" ])

    assert_equal :ready, status.state
    assert status.ready?
    assert_match "STRAD_API_KEY", status.summary
  end

  # The bug this pins: a resolvable static-header credential under a vendor's own
  # header name was read as "no OAuth credential stored yet", so a connector that
  # is fully configured asked its user to complete an OAuth flow that does not
  # exist for it — and that no consent screen could ever satisfy.
  test "a static-header server is ready whatever the vendor named its header" do
    status = probe("google-maps", VENDOR_HEADER_SERVER, resolvable: [ "GOOGLE_MAPS_API_KEY" ])

    assert_equal :ready, status.state
    refute status.authorizable?, "a static API key is not something OAuth can mint"
    assert_match "GOOGLE_MAPS_API_KEY", status.summary
  end

  # The other half of the same rule: the header being static does not excuse its
  # ${VAR} from resolving, and the fix must not turn an unset key into "ready".
  test "a vendor-header server with an unset key is missing configuration, not needing OAuth" do
    status = probe("google-maps", VENDOR_HEADER_SERVER)

    assert_equal :missing_configuration, status.state
    assert_equal [ "GOOGLE_MAPS_API_KEY" ], status.missing_variables
    refute status.authorizable?
  end

  test "an OAuth server with an active stored credential is ready" do
    with_catalog("notion", OAUTH_SERVER) do
      create_credential("notion", OAUTH_SERVER, expires_at: 2.hours.from_now)
    end

    status = probe("notion", OAUTH_SERVER)

    assert_equal :ready, status.state
    assert_match "OAuth is complete", status.summary
    assert_not_nil status.credential
  end

  test "a credential with no expiry is ready and says so" do
    with_catalog("notion", OAUTH_SERVER) do
      create_credential("notion", OAUTH_SERVER, expires_at: nil)
    end

    status = probe("notion", OAUTH_SERVER)

    assert_equal :ready, status.state
    assert_match "does not expire", status.summary
  end

  # --- OAuth states ----------------------------------------------------------

  test "an OAuth server with no credential needs authorization" do
    status = probe("notion", OAUTH_SERVER)

    assert_equal :needs_authorization, status.state
    assert status.actionable?
    assert status.authorizable?, "the Connectors page can start this flow"
    assert_match "you don't need a session", status.summary
  end

  test "an expired credential with a refresh token reports token expired" do
    with_catalog("notion", OAUTH_SERVER) do
      create_credential("notion", OAUTH_SERVER, expires_at: 1.hour.ago,
        refresh_token: "refresh", token_endpoint: "https://mcp.notion.example.com/token")
    end

    status = probe("notion", OAUTH_SERVER)

    assert_equal :token_expired, status.state
    assert_match "renew it automatically", status.summary
    assert_not status.authorizable?,
      "the refresh job fixes this one; offering a consent screen would be noise"
  end

  test "an expired credential with no refresh token reports needs re-auth" do
    with_catalog("notion", OAUTH_SERVER) do
      create_credential("notion", OAUTH_SERVER, expires_at: 1.hour.ago, refresh_token: nil, token_endpoint: nil)
    end

    status = probe("notion", OAUTH_SERVER)

    assert_equal :needs_reauth, status.state
    assert status.authorizable?, "nothing renews this credential but a fresh flow"
  end

  # --- one-shot credentials (no refresh token was ever issued) ---------------

  # The whole point of recording this at issuance: a ready row is the moment the
  # user is looking, and it is the last moment before the limitation bites.
  test "a ready credential the server issued without a refresh token says so up front" do
    with_catalog("notion", OAUTH_SERVER) do
      create_credential("notion", OAUTH_SERVER, expires_at: 2.hours.from_now,
        refresh_token: nil, refresh_token_unsupported: true)
    end

    status = probe("notion", OAUTH_SERVER)

    assert_equal :ready, status.state
    assert status.requires_periodic_reauth?, "a one-shot credential is flagged while it still works"
    assert_match "cannot be renewed", status.summary
    assert_no_match(/refreshed automatically/, status.summary)
  end

  test "a credential with a refresh token is not flagged for periodic re-auth" do
    with_catalog("notion", OAUTH_SERVER) do
      create_credential("notion", OAUTH_SERVER, expires_at: 2.hours.from_now,
        refresh_token: "refresh", token_endpoint: "https://mcp.notion.example.com/token")
    end

    status = probe("notion", OAUTH_SERVER)

    assert_equal :ready, status.state
    assert_not status.requires_periodic_reauth?
    assert_match "refreshed automatically", status.summary
  end

  # A refresh token acquired later (a runtime-captured rotation, a re-auth
  # against a server that changed its mind) settles the question — the recorded
  # flag must not keep warning about a limitation that no longer applies.
  test "a refresh token that arrives later clears the periodic re-auth warning" do
    with_catalog("notion", OAUTH_SERVER) do
      create_credential("notion", OAUTH_SERVER, expires_at: 2.hours.from_now,
        refresh_token: "arrived-later", refresh_token_unsupported: true,
        token_endpoint: "https://mcp.notion.example.com/token")
    end

    status = probe("notion", OAUTH_SERVER)

    assert_not status.requires_periodic_reauth?
  end

  test "a server with no credential at all is not flagged for periodic re-auth" do
    status = probe("notion", OAUTH_SERVER)

    assert_equal :needs_authorization, status.state
    assert_not status.requires_periodic_reauth?, "no credential means no claim either way"
  end

  test "a credential stored under a different credential key does not count as ready" do
    with_catalog("notion", OAUTH_SERVER) do
      McpOauthCredential.create!(
        server_name: "notion",
        server_url: OAUTH_SERVER["url"],
        credential_key: "notion|staleconfighash",
        client_id: "client",
        access_token: "token",
        expires_at: 2.hours.from_now
      )
    end

    status = probe("notion", OAUTH_SERVER)

    assert_equal :needs_authorization, status.state,
      "a credential the injector would not find must not be reported as usable"
  end

  # --- no credential required ------------------------------------------------

  test "a stdio server with no interpolations requires no credential" do
    status = probe("context7", STDIO_NO_SECRETS)

    assert_equal :no_credential_required, status.state
    assert_not status.actionable?
  end

  # --- the secret store is unreachable ---------------------------------------

  test "a store that cannot be reached is not reported as a missing secret" do
    status = probe("secrets-service-account", SECRETS_SERVICE_ACCOUNT,
      unavailable_vars: { "STRAD_API_KEY" => "GET /parameters failed: 503" })

    assert_equal :store_unavailable, status.state
    assert_equal "Secret store unreachable", status.label
    assert_match "503", status.summary
    assert_match "not the same as the variable being unset", status.summary
  end

  test "an unreachable store offers no set-it-here instructions" do
    status = probe("secrets-service-account", SECRETS_SERVICE_ACCOUNT,
      unavailable_vars: { "STRAD_API_KEY" => "boom" })

    assert_empty status.instructions,
      "telling someone to go set a secret that may already be there is worse than saying nothing"
  end

  # --- failure isolation -----------------------------------------------------

  test "an unexpected error degrades to probe failed instead of raising" do
    McpOauthCredentialInjector.stubs(:oauth_capable_server?).raises(RuntimeError, "catalog exploded")

    status = probe("notion", OAUTH_SERVER)

    assert_equal :probe_failed, status.state
    assert_match "catalog exploded", status.summary
  end

  test ".for returns nil for a server that is not in the catalog" do
    with_catalog("notion", OAUTH_SERVER) do
      assert_nil ConnectorStatusProbe.for("not-a-real-server")
    end
  end

  test ".for probes a catalog server by name" do
    with_catalog("context7", STDIO_NO_SECRETS) do
      assert_equal :no_credential_required, ConnectorStatusProbe.for("context7").state
    end
  end


  # --- secret-source badges ---------------------------------------------------

  test "each required variable reports the provider that actually resolved it" do
    fake = FakeParameterStore.new
    fake.seed_secret("STRAD_API_KEY", "sk-live")
    SecretProviders.stubs(:chain).returns(
      SecretProviders::Chain.new([ fake.provider, SecretProviders::RailsCredentials.new ])
    )

    status = with_catalog("secrets-service-account", SECRETS_SERVICE_ACCOUNT) do
      ConnectorStatusProbe.new(server("secrets-service-account", SECRETS_SERVICE_ACCOUNT)).call
    end

    source = status.variable_sources.sole
    assert_equal "STRAD_API_KEY", source.variable
    assert_equal "GSM", source.badge
    assert_match "Google Secret Manager", source.title
    assert source.resolved?
  end

  test "the badge names the winning provider, not every provider holding the name" do
    # The store and the credentials file both hold it. GSM wins the chain, so GSM
    # is what a spawn uses, so GSM is what the badge must say.
    fake = FakeParameterStore.new
    fake.seed_secret("STRAD_API_KEY", "from-the-store")
    SecretsLoader.stubs(:exists?).returns(false)
    SecretsLoader.stubs(:exists?).with("STRAD_API_KEY").returns(true)
    SecretsLoader.stubs(:get).with("STRAD_API_KEY").returns("from-the-credentials-file")
    SecretProviders.stubs(:chain).returns(
      SecretProviders::Chain.new([ fake.provider, SecretProviders::RailsCredentials.new ])
    )

    status = with_catalog("secrets-service-account", SECRETS_SERVICE_ACCOUNT) do
      ConnectorStatusProbe.new(server("secrets-service-account", SECRETS_SERVICE_ACCOUNT)).call
    end

    assert_equal "GSM", status.variable_sources.sole.badge
  end

  test "a variable resolved from the encrypted credentials badges Rails Credentials" do
    SecretsLoader.stubs(:exists?).returns(false)
    SecretsLoader.stubs(:exists?).with("SLACK_BOT_TOKEN").returns(true)
    SecretsLoader.stubs(:get).with("SLACK_BOT_TOKEN").returns("xoxb")
    SecretProviders.stubs(:chain).returns(
      SecretProviders::Chain.new([ SecretProviders::RailsCredentials.new, SecretProviders::Env.new({}) ])
    )

    status = with_catalog("slack-workspace", STDIO_WITH_SECRET) do
      ConnectorStatusProbe.new(server("slack-workspace", STDIO_WITH_SECRET)).call
    end

    assert_equal "Rails Credentials", status.variable_sources.sole.badge
  end

  test "a variable resolved from the process environment badges ENV" do
    SecretsLoader.stubs(:exists?).returns(false)
    SecretProviders.stubs(:chain).returns(
      SecretProviders::Chain.new([
        SecretProviders::RailsCredentials.new,
        SecretProviders::Env.new({ "SLACK_BOT_TOKEN" => "xoxb-from-env" })
      ])
    )

    status = with_catalog("slack-workspace", STDIO_WITH_SECRET) do
      ConnectorStatusProbe.new(server("slack-workspace", STDIO_WITH_SECRET)).call
    end

    assert_equal "ENV", status.variable_sources.sole.badge
  end

  test "an unset variable is its own badge, not a blank one" do
    status = probe("secrets-service-account", SECRETS_SERVICE_ACCOUNT)

    source = status.variable_sources.sole
    assert_equal "Unresolved", source.badge
    assert_not source.resolved?
  end

  test "a variable the store could not be asked about is Unknown, not Unresolved" do
    status = probe("secrets-service-account", SECRETS_SERVICE_ACCOUNT,
      unavailable_vars: { "STRAD_API_KEY" => "boom" })

    assert_equal "Unknown", status.variable_sources.sole.badge
  end

  test "badges survive every state, including a server with several variables" do
    config = STDIO_WITH_SECRET.merge("env" => { "A" => "${ALPHA}", "B" => "${BETA}" })
    status = probe("multi", config, resolvable: [ "ALPHA" ])

    assert_equal %w[ALPHA BETA], status.variable_sources.map(&:variable).sort
    assert_equal [ "Unresolved" ], status.variable_sources.reject(&:resolved?).map(&:badge)
  end

  private

  def create_credential(name, config, **attrs)
    McpOauthCredential.create!({
      server_name: name,
      server_url: config["url"],
      credential_key: McpOauthCredential.compute_credential_key(name, ServersConfig.credential_config(name)),
      client_id: "client-id",
      access_token: "access-token"
    }.merge(attrs))
  end
end
