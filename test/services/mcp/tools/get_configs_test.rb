# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# get_configs is the agent's front door onto the catalog, and it reads through
# the same façades the session form does — the ones that rescue CatalogError to
# an empty array. So a broken catalog renders as "No MCP servers available",
# indistinguishable from a fresh install, and an agent goes on to call
# start_session against it. That is #112 on the agent side of the wall.
class Mcp::Tools::GetConfigsTest < ActiveSupport::TestCase
  setup do
    @tool = Mcp::Tools::GetConfigs.new(context: Mcp::Context.new(tool_groups: "sessions"))
  end

  teardown do
    Mocha::Mockery.instance.teardown
  end

  test "says nothing about catalog health when the catalog resolves" do
    AirCatalogService.stubs(:resolve_failure).returns(nil)

    result = @tool.call({})

    refute_includes result, "Catalog resolution is failing"
    assert_includes result, "## MCP Servers"
  end

  test "lists runtime model catalogs for model discovery" do
    result = @tool.call({})

    assert_includes result, "## Runtime Models"
    assert_includes result, "### Claude Code"
    assert_includes result, "- **Runtime:** `claude_code`"
    assert_includes result, "- **Default Model:** `opus`"
    assert_includes result, "`fable`"
    assert_includes result, "### Codex"
    assert_includes result, "- **Runtime:** `codex`"
    assert_includes result, "- **Default Model:** `gpt-5.6-terra`"
    assert_includes result, "`gpt-5.6-sol` (requires OAuth)"
    assert_includes result, "`gpt-5.6-terra` (default, requires OAuth)"
    assert_includes result, "`gpt-5.6-luna` (requires OAuth)"
  end

  test "warns that empty lists are a resolution failure, not an empty catalog" do
    AirCatalogService.stubs(:resolve_failure).returns({ message: "boom", at: Time.utc(2026, 8, 1, 12, 0, 0) })
    AirCatalogService.stubs(:degraded?).returns(false)

    result = @tool.call({})

    assert_includes result, "Catalog resolution is failing"
    assert_includes result, "**because of the failure**"
    assert_includes result, "expect `start_session` to fail"
    assert_includes result, "2026-08-01T12:00:00Z"
  end

  test "warns that the lists are stale when a last-known-good catalog is being served" do
    AirCatalogService.stubs(:resolve_failure).returns({ message: "boom", at: Time.utc(2026, 8, 1, 12, 0, 0) })
    AirCatalogService.stubs(:degraded?).returns(true)
    AirCatalogService.stubs(:last_known_good_at).returns(Time.utc(2026, 8, 1, 10, 0, 0))

    result = @tool.call({})

    assert_includes result, "Catalog resolution is failing"
    assert_includes result, "last catalog that resolved successfully"
    assert_includes result, "2026-08-01T10:00:00Z"
  end

  # --- availability ----------------------------------------------------------
  #
  # The list an agent reads as "your options" must not contain a server that
  # cannot start. An unresolved `${VAR}` is not a soft failure: SecretsInterpolator
  # raises at spawn and takes the whole session with it, not just that server.

  # A catalog shaped like the real one at the time of writing: two servers that
  # work, one whose secret is not seeded, and one the catalog itself declares
  # dead.
  CATALOG = {
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
  def with_mixed_catalog(roots: {})
    AirCatalogService.stubs(:entries_for).returns({})
    AirCatalogService.stubs(:entries_for).with(:mcp).returns(CATALOG)
    AirCatalogService.stubs(:entries_for).with(:roots).returns(roots)
    found = SecretsInterpolator::Resolution.new(state: :found, source: "a stubbed provider")
    SecretsInterpolator.any_instance.stubs(:resolution).returns(found)
    SecretsInterpolator.any_instance.stubs(:resolution).with("STRAD_STAGING_API_KEY")
      .returns(SecretsInterpolator::Resolution.new(state: :absent))
    yield
  end

  test "a server that cannot start is not offered as an option" do
    result = with_mixed_catalog { @tool.call({}) }

    assert_includes result, "### Context7", "a healthy server is listed as it always was"
    assert_includes result, "- **Name:** `zimmer-self-session`"
    refute_includes result, "### Strad Secrets Staging",
      "an unresolved ${VAR} raises at spawn — this is not an option"
    refute_includes result, "### Strad Secrets (OAuth)"
    refute_includes result, "Staging secrets, read-write.",
      "the roster names it; it does not re-describe it"
  end

  test "the unavailable roster names each one with a reason, so it reads as broken rather than absent" do
    result = with_mixed_catalog { @tool.call({}) }

    assert_includes result, "### Unavailable"
    assert_includes result, "- `strad-secrets-staging-rw` — unavailable: `STRAD_STAGING_API_KEY` unresolved"
    assert_includes result, "- `strad-secrets-oauth` — unavailable: The endpoint accepts only static " \
                            "bearer tokens and exposes no OAuth discovery."
    assert_includes result, "do not register a replacement"
  end

  # Whatever the split, every catalog entry is accounted for — an agent can tell
  # from the header alone that nothing went missing silently.
  test "the counts add up to the whole catalog" do
    result = with_mixed_catalog { @tool.call({}) }

    assert_includes result, "Found 2 usable servers (of 4 in the catalog; the other 2 are unavailable, listed below):"
    assert_equal 2, result.scan(/^- `[a-z0-9-]+` — unavailable:/).size
  end

  # The whole rendered section, asserted as one string: the format an agent
  # actually reads, not a set of substrings that could each pass while the
  # section around them is mangled.
  test "renders the MCP servers section exactly" do
    result = with_mixed_catalog { @tool.call({}) }
    section = result[/## MCP Servers\n.*?\n---\n/m]

    assert_equal <<~SECTION, section
      ## MCP Servers

      Found 2 usable servers (of 4 in the catalog; the other 2 are unavailable, listed below):

      ### Context7
      - **Name:** `context7`
      - **Description:** Up-to-date library documentation lookup.

      ### Zimmer Self Session
      - **Name:** `zimmer-self-session`
      - **Description:** Zimmer's own session tools.

      ### Unavailable

      2 catalog servers cannot be attached right now. They exist — do not register a replacement — but do not pass them to `start_session`. Each line says why, and the reasons fail differently: an unresolved `${VAR}` raises at spawn and fails the whole session rather than just that server, while a server awaiting OAuth parks it for a human to authorize at /connectors.

      - `strad-secrets-staging-rw` — unavailable: `STRAD_STAGING_API_KEY` unresolved
      - `strad-secrets-oauth` — unavailable: The endpoint accepts only static bearer tokens and exposes no OAuth discovery.

      ---
    SECTION
  end

  # One unavailable server is the likeliest real state, and the count appears in
  # two sentences that have to agree with each other.
  test "the header and the roster agree when exactly one server is unavailable" do
    AirCatalogService.stubs(:entries_for).returns({})
    AirCatalogService.stubs(:entries_for).with(:mcp)
      .returns(CATALOG.slice("context7", "strad-secrets-oauth"))
    SecretsInterpolator.any_instance.stubs(:resolution)
      .returns(SecretsInterpolator::Resolution.new(state: :found, source: "a stubbed provider"))

    result = @tool.call({})

    assert_includes result, "Found 1 usable server (of 2 in the catalog; the other 1 is unavailable, listed below):"
    assert_includes result, "1 catalog server cannot be attached right now. It exists"
    refute_includes result, "1 are unavailable"
  end

  # The roster's four states do not fail the same way, and an agent told only
  # about `${VAR}` goes hunting for a secret when the answer is an OAuth flow.
  test "the roster explains both ways an unavailable server fails" do
    result = with_mixed_catalog { @tool.call({}) }

    assert_includes result, "raises at spawn and fails the whole session"
    assert_includes result, "awaiting OAuth parks it for a human to authorize"
  end

  test "an unavailable server a root defaults to is marked, not silently dropped" do
    roots = {
      "zimmer" => {
        "title" => "Zimmer", "description" => "The app.", "url" => "https://github.com/tadasant/zimmer",
        "default_mcp_servers" => %w[context7 strad-secrets-staging-rw]
      }
    }
    result = with_mixed_catalog(roots: roots) { @tool.call({}) }

    assert_includes result,
      "- **Default MCP Servers (omit `mcp_servers` to take all of these):** `context7`, " \
      "`strad-secrets-staging-rw` (unavailable)"
  end

  # The failure this warning exists for: a router passed one of a root's two
  # default servers, the other was dropped without a word, and a skill that
  # depended on it ran with nothing to call.
  # https://github.com/tadasant/tadasant-internal/issues/2145
  test "the usage notes warn that a list passed to start_session replaces the root's defaults" do
    result = with_mixed_catalog { @tool.call({}) }

    assert_includes result, "REPLACES the root's defaults, it is not added to them"
    assert_includes result, "every default you did not name dropped silently"
    assert_includes result, "a root's default skill can depend on a root's default server"
  end

  # A store outage makes every variable indeterminate at once. Omitting the
  # catalog wholesale because Google did not answer is the worse failure: an
  # agent that sees no servers concludes there are none.
  test "a secret store outage does not empty the option list" do
    AirCatalogService.stubs(:entries_for).returns({})
    AirCatalogService.stubs(:entries_for).with(:mcp).returns(CATALOG)
    outage = SecretsInterpolator::Resolution.new(state: :unavailable,
      error: ParameterStore::StoreError.new("store did not answer", 503))
    SecretsInterpolator.any_instance.stubs(:resolution).returns(outage)

    result = @tool.call({})

    assert_includes result, "- **Name:** `zimmer-self-session`"
    assert_includes result, "- **Name:** `strad-secrets-staging-rw`"
    assert_includes result, "- `strad-secrets-oauth` — unavailable:",
      "a standing declaration does not depend on the store"
  end

  test "says so plainly when nothing is usable" do
    AirCatalogService.stubs(:entries_for).returns({})
    AirCatalogService.stubs(:entries_for).with(:mcp)
      .returns(CATALOG.slice("strad-secrets-staging-rw", "strad-secrets-oauth"))
    SecretsInterpolator.any_instance.stubs(:resolution)
      .returns(SecretsInterpolator::Resolution.new(state: :absent))

    result = @tool.call({})

    assert_includes result, "*Every catalog server is currently unavailable — see below.*"
    assert_includes result, "### Unavailable"
  end

  test "an empty catalog is still an empty catalog, not an unavailable one" do
    AirCatalogService.stubs(:entries_for).returns({})

    result = @tool.call({})

    assert_includes result, "*No MCP servers available.*"
    refute_includes result, "### Unavailable"
  end

  # The session form prints `air resolve`'s stderr verbatim for an operator. That
  # process is handed AIR_GITHUB_TOKEN, so the same text must not travel to an
  # agent: the MCP surface carries the fact and its age, never the message.
  test "never echoes the resolve error onto the agent channel" do
    secret = "fatal: could not read Password for 'https://ghp_supersecrettoken@github.com'"
    AirCatalogService.stubs(:resolve_failure).returns({ message: secret, at: Time.current })
    AirCatalogService.stubs(:degraded?).returns(false)

    result = @tool.call({})

    assert_includes result, "Catalog resolution is failing"
    refute_includes result, secret
    refute_includes result, "ghp_supersecrettoken"
  end
end
