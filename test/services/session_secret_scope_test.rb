# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"
require "tmpdir"

# Tests for SessionSecretScope — which of Zimmer's secrets a clone may hold.
#
# Every assertion here is on variable NAMES. No test in this file constructs,
# stores or prints a secret VALUE, because the whole point of the class is that
# the names are the interesting part and the values must never travel further
# than they have to.
class SessionSecretScopeTest < ActiveSupport::TestCase
  # Stand-in for the deployment's `mcp_secrets` bundle: the names only.
  BUNDLE = %w[
    SLACK_BOT_TOKEN
    ZIMMER_PROD_API_KEY
    STRAD_API_KEY
    GITHUB_PERSONAL_ACCESS_TOKEN
    CLOUDFLARE_API_TOKEN_DNS_READWRITE
    GCS_ADMIN_SERVICE_ACCOUNT_KEY_JSON
  ].freeze

  def session(**attrs)
    Session.new({
      mcp_servers: [], catalog_skills: [], catalog_hooks: [],
      catalog_plugins: [], custom_metadata: {}
    }.merge(attrs))
  end

  def allowed(session, env: {})
    SessionSecretScope.allowed_keys(session: session, available_keys: BUNDLE, env: env)
  end

  # ---------------------------------------------------------------------------
  # The MCP-server union — the bulk of the rule
  # ---------------------------------------------------------------------------

  test "a session gets the variables its own MCP servers declare, and nothing else" do
    assert_equal %w[SLACK_BOT_TOKEN], allowed(session(mcp_servers: %w[slack-workspace]))
  end

  test "a server declaring no variable contributes nothing" do
    assert_empty allowed(session(mcp_servers: %w[playwright-custom context7 linear]))
  end

  test "two servers union rather than replace" do
    assert_equal %w[SLACK_BOT_TOKEN ZIMMER_PROD_API_KEY],
      allowed(session(mcp_servers: %w[slack-workspace zimmer-sessions]))
  end

  test "a session with no artifacts at all gets no secrets" do
    assert_empty allowed(session)
  end

  test "the whole bundle is never the answer for a narrowly-provisioned session" do
    keys = allowed(session(mcp_servers: %w[slack-workspace]))

    assert_not_includes keys, "CLOUDFLARE_API_TOKEN_DNS_READWRITE"
    assert_not_includes keys, "GCS_ADMIN_SERVICE_ACCOUNT_KEY_JSON"
    assert_not_includes keys, "GITHUB_PERSONAL_ACCESS_TOKEN"
  end

  test "a variable the deployment does not hold is dropped rather than written empty" do
    server = ServersConfig::Server.new("acme", {
      "type" => "stdio", "command" => "npx", "env" => { "ACME" => "${ACME_TOKEN_NOBODY_HAS}" }
    })
    ServersConfig.stubs(:find).with("acme").returns(server)

    assert_empty allowed(session(mcp_servers: %w[acme]))
  end

  test "an optional ${VAR:-default} still reaches the clone" do
    server = ServersConfig::Server.new("acme", {
      "type" => "stdio", "command" => "npx",
      "env" => { "A" => "${STRAD_API_KEY:-none}", "B" => "${SLACK_BOT_TOKEN}" }
    })
    ServersConfig.stubs(:find).with("acme").returns(server)

    assert_equal %w[SLACK_BOT_TOKEN STRAD_API_KEY], allowed(session(mcp_servers: %w[acme]))
  end

  test "a plugin-bundled server counts as selected" do
    plugin_session = session(catalog_plugins: %w[screenshots-videos])

    assert_includes plugin_session.user_selected_mcp_servers, "remote-fs-screenshots",
      "the plugin is what puts this server on the session"

    # Stubbed rather than read off the catalog: what is being asserted is that a
    # plugin-derived server's declaration reaches the scope, not which variable
    # the catalog's remote-fs-screenshots happens to declare this month.
    ServersConfig.stubs(:find).returns(nil)
    ServersConfig.stubs(:find).with("remote-fs-screenshots").returns(
      ServersConfig::Server.new("remote-fs-screenshots", {
        "type" => "streamable-http", "url" => "https://example.test/mcp",
        "headers" => { "Authorization" => "Bearer ${STRAD_API_KEY}" }
      })
    )

    assert_equal %w[STRAD_API_KEY], allowed(plugin_session)
  end

  test "an auto-injected Zimmer server does not hand its API key to the clone" do
    # zimmer-self-session is injected into every session and its catalog entry
    # authenticates with ${ZIMMER_PROD_API_KEY}; Zimmer resolves that into the
    # entry's own header, so the shell never needs it.
    injected = session(custom_metadata: { "injected_mcp_servers" => %w[zimmer-self-session] })

    assert_empty allowed(injected)
  end

  test "a Zimmer server someone selected by name does bring its key" do
    assert_equal %w[ZIMMER_PROD_API_KEY], allowed(session(mcp_servers: %w[zimmer-sessions]))
  end

  test "an unknown server id contributes nothing instead of raising" do
    assert_empty allowed(session(mcp_servers: %w[no-such-server-anywhere]))
  end

  test "a catalog that cannot be read fails closed, not open" do
    ServersConfig.stubs(:find).raises(ServersConfig::ConfigurationError, "catalog down")

    assert_empty allowed(session(mcp_servers: %w[slack-workspace])),
      "a broken catalog must not silently restore the whole bundle"
  end

  # ---------------------------------------------------------------------------
  # The skill/hook scan — for credentials no server declares
  # ---------------------------------------------------------------------------

  test "a skill that tells the agent to use $VAR gets that variable" do
    with_artifact_dir("SKILL.md" => "Run `curl -H \"Authorization: Bearer $STRAD_API_KEY\"`") do |dir|
      SkillsConfig.stubs(:find).with("secrets-skill")
        .returns(SkillsConfig::Skill.new("secrets-skill", "path" => dir))

      assert_equal %w[STRAD_API_KEY], allowed(session(catalog_skills: %w[secrets-skill]))
    end
  end

  test "a skill body scan reaches files below the skill's top level" do
    with_artifact_dir(
      "SKILL.md" => "see scripts/run.sh",
      "scripts/run.sh" => "gh auth login --with-token <<< \"${GITHUB_PERSONAL_ACCESS_TOKEN}\""
    ) do |dir|
      SkillsConfig.stubs(:find).with("deep-skill")
        .returns(SkillsConfig::Skill.new("deep-skill", "path" => dir))

      assert_equal %w[GITHUB_PERSONAL_ACCESS_TOKEN], allowed(session(catalog_skills: %w[deep-skill]))
    end
  end

  test "prose naming a variable without a sigil does not hand it over" do
    with_artifact_dir("SKILL.md" => "The deployment sets `SLACK_BOT_TOKEN` in its credentials.") do |dir|
      SkillsConfig.stubs(:find).with("prose-skill")
        .returns(SkillsConfig::Skill.new("prose-skill", "path" => dir))

      assert_empty allowed(session(catalog_skills: %w[prose-skill])),
        "talking about a variable is not using it"
    end
  end

  test "a skill cannot invent a secret the deployment does not hold" do
    with_artifact_dir("SKILL.md" => "$TOTALLY_MADE_UP_TOKEN and $PATH and $HOME") do |dir|
      SkillsConfig.stubs(:find).with("greedy-skill")
        .returns(SkillsConfig::Skill.new("greedy-skill", "path" => dir))

      assert_empty allowed(session(catalog_skills: %w[greedy-skill]))
    end
  end

  test "a hook is scanned the same way a skill is" do
    with_artifact_dir("hook.sh" => "echo $ZIMMER_PROD_API_KEY") do |dir|
      HooksConfig.stubs(:find).with("noisy-hook")
        .returns(HooksConfig::Hook.new("noisy-hook", "path" => dir))

      assert_equal %w[ZIMMER_PROD_API_KEY], allowed(session(catalog_hooks: %w[noisy-hook]))
    end
  end

  test "a symlink inside a skill directory is not followed" do
    Dir.mktmpdir("outside") do |outside|
      File.write(File.join(outside, "elsewhere.md"), "$STRAD_API_KEY")
      with_artifact_dir("SKILL.md" => "nothing here") do |dir|
        File.symlink(File.join(outside, "elsewhere.md"), File.join(dir, "linked.md"))
        SkillsConfig.stubs(:find).with("linky-skill")
          .returns(SkillsConfig::Skill.new("linky-skill", "path" => dir))

        assert_empty allowed(session(catalog_skills: %w[linky-skill]))
      end
    end
  end

  test "a skill whose directory is missing contributes nothing instead of raising" do
    SkillsConfig.stubs(:find).with("ghost-skill")
      .returns(SkillsConfig::Skill.new("ghost-skill", "path" => "/nonexistent/skill/dir"))

    assert_empty allowed(session(catalog_skills: %w[ghost-skill]))
  end

  test "a file over the per-file cap is skipped rather than read into memory" do
    with_artifact_dir("SKILL.md" => "$STRAD_API_KEY#{'x' * SessionSecretScope::MAX_BYTES_PER_FILE}") do |dir|
      SkillsConfig.stubs(:find).with("huge-skill")
        .returns(SkillsConfig::Skill.new("huge-skill", "path" => dir))

      assert_empty allowed(session(catalog_skills: %w[huge-skill]))
    end
  end

  # ---------------------------------------------------------------------------
  # The escape hatches
  # ---------------------------------------------------------------------------

  test "ZIMMER_SESSION_ENV_SCOPE=all restores the whole bundle" do
    keys = allowed(session(mcp_servers: %w[slack-workspace]), env: { "ZIMMER_SESSION_ENV_SCOPE" => "all" })

    assert_equal BUNDLE.sort, keys
    assert SessionSecretScope.unscoped?(env: { "ZIMMER_SESSION_ENV_SCOPE" => "ALL" })
  end

  test "any other value of ZIMMER_SESSION_ENV_SCOPE means scoped" do
    assert_not SessionSecretScope.unscoped?(env: {})
    assert_not SessionSecretScope.unscoped?(env: { "ZIMMER_SESSION_ENV_SCOPE" => "scoped" })
    assert_not SessionSecretScope.unscoped?(env: { "ZIMMER_SESSION_ENV_SCOPE" => "" })
  end

  test "ZIMMER_SESSION_ENV_EXTRA_KEYS adds names, still intersected with the bundle" do
    keys = allowed(
      session(mcp_servers: %w[slack-workspace]),
      env: { "ZIMMER_SESSION_ENV_EXTRA_KEYS" => " STRAD_API_KEY , NOT_A_REAL_SECRET ,, " }
    )

    assert_equal %w[SLACK_BOT_TOKEN STRAD_API_KEY], keys
  end

  test "the result is sorted and free of duplicates" do
    keys = allowed(
      session(mcp_servers: %w[slack-workspace zimmer-sessions]),
      env: { "ZIMMER_SESSION_ENV_EXTRA_KEYS" => "SLACK_BOT_TOKEN" }
    )

    assert_equal keys.sort, keys
    assert_equal keys.uniq, keys
  end

  private

  def with_artifact_dir(files)
    Dir.mktmpdir("scope-artifact") do |dir|
      files.each do |relative, content|
        path = File.join(dir, relative)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, content)
      end
      yield dir
    end
  end
end
