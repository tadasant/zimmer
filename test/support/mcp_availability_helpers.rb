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
  # the catalog itself declares dead.
  AVAILABILITY_CATALOG = {
    "context7" => {
      "title" => "Context7", "description" => "Up-to-date library documentation lookup.",
      "type" => "stdio", "command" => "npx", "args" => [ "-y", "@upstash/context7-mcp@latest" ]
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
  def with_mixed_availability_catalog(resolution: SecretsInterpolator::Resolution.new(state: :absent))
    AirCatalogService.stubs(:entries_for).returns({})
    AirCatalogService.stubs(:entries_for).with(:mcp).returns(AVAILABILITY_CATALOG)
    found = SecretsInterpolator::Resolution.new(state: :found, source: "a stubbed provider")
    SecretsInterpolator.any_instance.stubs(:resolution).returns(found)
    SecretsInterpolator.any_instance.stubs(:resolution).with("STRAD_STAGING_API_KEY").returns(resolution)
    yield
  end

  # The option `McpServerOptions` built for one server name.
  def option_for(options, name)
    options.find { |option| option[:name] == name || option["name"] == name }
  end
end
