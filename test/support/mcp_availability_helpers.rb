# frozen_string_literal: true

# A catalog with one server of every availability shape, for the surfaces that
# have to say whether Zimmer can start a server: the web pickers
# (`McpServerOptions`), `GET /api/v1/configs` and `GET /api/v1/mcp_servers`.
#
# Deliberately the same fixture shape `get_configs_test.rb` uses, because the
# whole point of `McpServerOptions` is that the human surfaces and the agent
# surface partition the catalog identically. A test that seeds a different
# catalog here could not catch the two drifting apart.
module McpAvailabilityHelpers
  # Two servers that work, one whose required `${VAR}` is not seeded, and one
  # the catalog itself declares dead. `context7` also declares a startup budget
  # of its own, so the surfaces that carry `startup_timeout_sec` are exercised
  # against an entry that names one and three that do not.
  AVAILABILITY_CATALOG = {
    "context7" => {
      "title" => "Context7", "description" => "Up-to-date library documentation lookup.",
      "type" => "stdio", "command" => "npx", "args" => [ "-y", "@upstash/context7-mcp@latest" ],
      "startup_timeout_sec" => 20
    },
    "zimmer-self-session" => {
      "title" => "Zimmer Self Session", "description" => "Zimmer's own session tools.",
      "type" => "streamable-http", "url" => "https://zimmer.example.com/mcp",
      "headers" => { "X-API-Key" => "${ZIMMER_PROD_API_KEY}" }
    },
    "strad-secrets-staging-rw" => {
      "title" => "Strad Secrets Staging", "description" => "Staging secrets, read-write.",
      "type" => "streamable-http", "url" => "https://staging.example.com/mcp",
      "headers" => { "Authorization" => "Bearer ${STRAD_STAGING_API_KEY}" }
    },
    "strad-secrets-oauth" => {
      "title" => "Strad Secrets (OAuth)", "description" => "Secrets over OAuth.",
      "type" => "streamable-http", "url" => "https://secrets.example.com/mcp",
      "unavailable" => "The endpoint accepts only static bearer tokens and exposes no OAuth discovery."
    }
  }.freeze

  # Seeds the catalog above and resolves every variable except the staging key,
  # so exactly one server is unavailable for a missing secret and one by
  # declaration.
  #
  # @param resolution [SecretsInterpolator::Resolution] what the providers say
  #   about STRAD_STAGING_API_KEY. Override it to exercise the states that mean
  #   "Zimmer could not find out" rather than "the answer is no".
  #
  # This stubs, so a file calling it needs `require "mocha/minitest"`. The
  # require belongs there and not here: this file is auto-required by
  # test_helper.rb, so a require here would be a suite-wide one (#874).
  def with_mixed_availability_catalog(resolution: SecretsInterpolator::Resolution.new(state: :absent))
    AirCatalogService.stubs(:entries_for).returns({})
    AirCatalogService.stubs(:entries_for).with(:mcp).returns(AVAILABILITY_CATALOG)
    found = SecretsInterpolator::Resolution.new(state: :found, source: "a stubbed provider")
    SecretsInterpolator.any_instance.stubs(:resolution).returns(found)
    SecretsInterpolator.any_instance.stubs(:resolution).with("STRAD_STAGING_API_KEY").returns(resolution)
    yield
  end

  # The mixed-availability MCP catalog above, with every OTHER artifact type
  # left real.
  #
  # `with_mixed_availability_catalog` blanks the rest, which is right for a test
  # that only reads a picker. A test of a WRITE path cannot use it: creating a
  # session needs an agent root, and the web form cannot even be submitted
  # without one. So this stubs the `mcp` slice only and passes every other type
  # through to whatever the real catalog resolved.
  #
  # After this, exactly two catalog servers are unstartable — `strad-secrets-staging-rw`
  # for an unresolved `${VAR}` (`:missing_configuration`) and `strad-secrets-oauth`
  # by catalog declaration (`:declared_unavailable`) — and `context7` and
  # `zimmer-self-session` both start. Every write-path test drives the real
  # `ConnectorStatusProbe` against that, rather than stubbing the readiness
  # answer, so the wiring under test is the wiring that ships.
  #
  # Stubs, so a file calling it needs `require "mocha/minitest"` — see the note
  # on the helper above.
  def with_mixed_mcp_catalog_only
    real = AirCatalogService::ARTIFACT_TYPES.index_with { |type| AirCatalogService.entries_for(type) }
    AirCatalogService.stubs(:entries_for).returns({})
    real.each do |type, entries|
      AirCatalogService.stubs(:entries_for).with(type)
        .returns(type == :mcp ? AVAILABILITY_CATALOG : entries)
    end
    SecretsInterpolator.any_instance.stubs(:resolution)
      .returns(SecretsInterpolator::Resolution.new(state: :found, source: "a stubbed provider"))
    SecretsInterpolator.any_instance.stubs(:resolution).with("STRAD_STAGING_API_KEY")
      .returns(SecretsInterpolator::Resolution.new(state: :absent))
    McpServerOptions::Cache.reset
    yield
  ensure
    McpServerOptions::Cache.reset
  end

  # The option `McpServerOptions` built for one server name.
  def option_for(options, name)
    options.find { |option| option[:name] == name || option["name"] == name }
  end

  # The item list the MCP `catalog-multiselect` widget was handed, read back off
  # the rendered page. Scoped by accent because all four catalog pickers on the
  # session page share the controller identifier; indigo is the MCP one.
  def mcp_multiselect_items
    value = css_select("[data-catalog-multiselect-accent-value='indigo']")
      .first["data-catalog-multiselect-items-value"]
    JSON.parse(value)
  end
end
