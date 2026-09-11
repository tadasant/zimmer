# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"

# zimmer#208, end to end, against a REAL `air resolve` of a REAL two-scope
# catalog: a local catalog and a composed `github://acme/catalog`, each
# contributing an artifact of every type under the same short id.
#
# Before this change the resolve itself hard-failed — Zimmer asked AIR for
# shortname-keyed output with `--no-scope`, which is only expressible in a
# single-scope universe — and the whole catalog degraded to last-known-good
# until an operator dropped one side via `air.json#exclude`.
#
# No network. The `github://` catalog is a directory planted in the AIR provider
# cache under a temporary HOME, which is the exact fast path
# `GitHubProvider#ensureClone` takes for an already-cloned repo (`.git` present →
# return, no fetch). The AIR CLI itself is the one test_helper installed.
class AirCatalogComposedCatalogTest < ActiveSupport::TestCase
  # Everything both catalogs contribute under the same short id — the collision
  # this test exists to prove is survivable, for every artifact type.
  CONTESTED = {
    mcp: "slack",
    skills: "shared-skill",
    roots: "shared-root",
    references: "shared-ref",
    hooks: "shared-hook",
    plugins: "shared-plugin"
  }.freeze

  setup do
    @original_air_path = Rails.application.config.air_json_path
    @original_home = ENV["HOME"]
    @tmpdir = Dir.mktmpdir("composed-catalog")

    build_github_catalog!
    build_local_catalog!

    # The provider reads its clone cache off HOME, and Open3 hands this
    # process's whole environment to the CLI. Restored in teardown.
    ENV["HOME"] = File.join(@tmpdir, "home")
    Rails.application.config.air_json_path = File.join(@tmpdir, "local", "air.json")

    AirCatalogService.reset!
    CatalogSnapshot.delete_all
  end

  teardown do
    ENV["HOME"] = @original_home
    Rails.application.config.air_json_path = @original_air_path
    AirCatalogService.reset!
    AirCatalogCacheWarmer.restore!
    FileUtils.rm_rf(@tmpdir) if @tmpdir && File.exist?(@tmpdir)
  end

  test "a cross-catalog shortname collision resolves instead of failing the whole catalog" do
    assert_equal %w[slack solo-server @acme/catalog/slack].sort,
      AirCatalogService.entries_for(:mcp).keys.sort
    refute AirCatalogService.degraded?,
      "a legitimate two-scope catalog must not degrade to last-known-good: " \
      "#{AirCatalogService.resolve_failure.inspect}"
    assert_nil AirCatalogService.resolve_failure
  end

  test "every artifact type keeps both sides of a collision as distinct entries" do
    CONTESTED.each do |type, short_id|
      keys = AirCatalogService.entries_for(type).keys
      assert_includes keys, short_id, "#{type}: the local side should keep the bare token"
      assert_includes keys, "@acme/catalog/#{short_id}", "#{type}: the composed side should be qualified"
    end
  end

  test "each catalog facade finds both sides, and a bare id still finds the local one" do
    assert_equal "Slack (local)", ServersConfig.find("slack").title
    assert_equal "Slack (acme)", ServersConfig.find("@acme/catalog/slack").title
    assert_equal "Slack (local)", ServersConfig.find("@local/slack").title
    assert ServersConfig.exists?("slack")
    assert ServersConfig.exists?("@acme/catalog/slack")

    assert_equal "Shared Skill (local)", SkillsConfig.find("shared-skill").title
    assert_equal "Shared Skill (acme)", SkillsConfig.find("@acme/catalog/shared-skill").title

    assert_equal "Shared Root (local)", AgentRootsConfig.find("shared-root").display_name
    assert_equal "Shared Root (acme)", AgentRootsConfig.find("@acme/catalog/shared-root").display_name

    assert_equal "Shared Ref (local)", ReferencesConfig.find("shared-ref").title
    assert_equal "Shared Ref (acme)", ReferencesConfig.find("@acme/catalog/shared-ref").title

    assert_equal "Shared Hook (local)", HooksConfig.find("shared-hook").title
    assert_equal "Shared Hook (acme)", HooksConfig.find("@acme/catalog/shared-hook").title

    assert_equal "Shared Plugin (local)", PluginsConfig.find("shared-plugin").title
    assert_equal "Shared Plugin (acme)", PluginsConfig.find("@acme/catalog/shared-plugin").title
  end

  test "an artifact reports the catalog it came from, and whether its short id is contested" do
    local = ServersConfig.find("slack")
    acme = ServersConfig.find("@acme/catalog/slack")
    solo = ServersConfig.find("solo-server")

    assert_equal "@local/slack", local.qualified_name
    assert_equal "local", local.scope
    assert local.contested?

    assert_equal "@acme/catalog/slack", acme.qualified_name
    assert_equal "acme/catalog", acme.scope
    assert acme.contested?
    assert_equal "slack", acme.short_id

    assert_equal "@local/solo-server", solo.qualified_name
    refute solo.contested?, "an uncontested artifact needs no qualification"
  end

  test "the MCP picker carries the scope only for the entries a human cannot otherwise tell apart" do
    options = ServersConfig.all.map { |server| McpServerOptions.send(:option, server, nil) }

    assert_equal "local", options.find { |o| o[:name] == "slack" }[:scope]
    assert_equal "acme/catalog", options.find { |o| o[:name] == "@acme/catalog/slack" }[:scope]
    assert_nil options.find { |o| o[:name] == "solo-server" }[:scope]
  end

  test "both sides of a collision are independently selectable for a session" do
    local_only = create_session!(mcp_servers: [ "slack" ], catalog_skills: [ "shared-skill" ])
    assert_equal [ "slack" ], local_only.mcp_servers

    acme_only = create_session!(
      mcp_servers: [ "@acme/catalog/slack" ],
      catalog_skills: [ "@acme/catalog/shared-skill" ]
    )
    assert_equal [ "@acme/catalog/slack" ], acme_only.mcp_servers

    # And a session can hold one of each type from both catalogs at once, as long
    # as no two of them share a short id.
    mixed = create_session!(
      mcp_servers: [ "solo-server", "@acme/catalog/slack" ],
      catalog_skills: [ "solo-skill", "@acme/catalog/shared-skill" ],
      catalog_hooks: [ "@acme/catalog/shared-hook" ],
      catalog_plugins: [ "shared-plugin" ]
    )
    assert_equal [ "solo-server", "@acme/catalog/slack" ], mixed.mcp_servers
    assert_equal [ "solo-skill", "@acme/catalog/shared-skill" ], mixed.catalog_skills
  end

  # `air prepare` writes an artifact under its SHORT name — `.mcp.json`'s
  # `mcpServers` key, `.claude/skills/<short-id>/` — so activating both sides at
  # once makes AIR exit non-zero with "would write to the same target name".
  # Rejecting the pair here turns a bricked session start into a field error.
  test "the two sides of a collision cannot be activated in the SAME session" do
    session = Session.new(
      prompt: "x", git_root: "https://github.com/tadasant/zimmer.git", branch: "main",
      mcp_servers: [ "slack", "@acme/catalog/slack" ]
    )

    refute session.valid?
    message = session.errors[:mcp_servers].join
    assert_includes message, "same short id"
    assert_includes message, "slack"
  end

  test "two artifacts with different short ids from two catalogs are not a collision" do
    session = Session.new(
      prompt: "x", git_root: "https://github.com/tadasant/zimmer.git", branch: "main",
      mcp_servers: [ "solo-server", "@acme/catalog/slack" ]
    )

    assert session.valid?, session.errors.full_messages.join("; ")
  end

  test "a session naming an artifact no scope resolves is still rejected" do
    session = Session.new(
      prompt: "x", git_root: "https://github.com/tadasant/zimmer.git", branch: "main",
      mcp_servers: [ "not-in-any-catalog" ]
    )

    refute session.valid?
    assert_includes session.errors[:mcp_servers].join, "not-in-any-catalog"
  end

  test "an existing-style session created against a bare agent_root name keeps working" do
    session = Session.create_from_agent_root!(agent_root_name: "solo-root", prompt: "bare id")

    assert_equal "solo-root", session.metadata["agent_root_key"]
    assert_equal "solo-root", AgentRootsConfig.find_for_session(session).name
    # And its root's defaults came back as bare tokens, not as `@local/...`.
    assert_equal [ "solo-skill" ], session.catalog_skills
    assert_equal [ "solo-server" ], session.mcp_servers
  end

  test "a root's defaults name the losing side of a collision by its qualified id" do
    acme_root = AgentRootsConfig.find("@acme/catalog/shared-root")

    assert_equal [ "@acme/catalog/shared-skill" ], acme_root.default_skills
    assert_equal [ "@acme/catalog/slack" ], acme_root.default_mcp_servers
  end

  test "a skill's references are rewritten back to Zimmer's own tokens" do
    assert_equal [ "shared-ref" ], SkillsConfig.find("solo-skill").references
    assert_equal [ "@acme/catalog/shared-ref" ],
      SkillsConfig.find("@acme/catalog/shared-skill").references
  end

  test "a contested id is qualified before it reaches the AIR CLI, and nothing else is" do
    # The @local side keeps the bare token in Zimmer, but AIR would call the bare
    # form ambiguous — so it is the side that MUST be expanded.
    assert_equal "@local/slack", AirCatalogService.air_reference(:mcp, "slack")
    assert_equal "@acme/catalog/slack", AirCatalogService.air_reference(:mcp, "@acme/catalog/slack")

    # Everything a single catalog contributes is handed over exactly as stored,
    # which is the whole argv on a single-scope deployment.
    assert_equal "solo-server", AirCatalogService.air_reference(:mcp, "solo-server")
    assert_equal "solo-root", AirCatalogService.air_reference(:roots, "solo-root")
    assert_equal "not-in-any-catalog", AirCatalogService.air_reference(:mcp, "not-in-any-catalog")

    assert_equal "@local/slack", AirCatalogService.qualified_id(:mcp, "slack")
    assert_nil AirCatalogService.qualified_id(:mcp, "not-in-any-catalog")
  end

  # `air prepare` hard-rejects an ambiguous bare shortname, so the expansion
  # above is not cosmetic — this asserts the argv AirPrepareService actually
  # builds carries the qualified form.
  test "air prepare is invoked with qualified ids for a contested artifact" do
    session = create_session!(
      mcp_servers: [ "@acme/catalog/slack" ],
      catalog_skills: [ "shared-skill" ],
      catalog_hooks: [ "@acme/catalog/shared-hook" ],
      catalog_plugins: [ "shared-plugin" ]
    )
    session.update!(metadata: (session.metadata || {}).merge("agent_root_key" => "solo-root"))
    service = AirPrepareService.new(session: session, working_directory: @tmpdir)
    cmd = nil

    AirPrepareService.stub(:ensure_air_installed!, nil) do
      service.stub(:catch_up_catalog_cache!, nil) do
        service.stub(:run_air_prepare_command!, ->(command, _env) { cmd = command }) do
          service.send(:run_air_prepare!)
        end
      end
    end

    pairs = cmd.each_cons(2).to_a
    # Uncontested: passed through exactly as Zimmer stores it.
    assert_equal "solo-root", cmd[cmd.index("--root") + 1]
    # Contested: qualified, on both sides of the collision.
    assert_includes pairs, [ "--mcp-server", "@acme/catalog/slack" ]
    assert_includes pairs, [ "--skill", "@local/shared-skill" ]
    assert_includes pairs, [ "--hook", "@acme/catalog/shared-hook" ]
    assert_includes pairs, [ "--plugin", "@local/shared-plugin" ]
  end

  private

  def create_session!(**attrs)
    Session.create!(
      {
        prompt: "composed catalog",
        git_root: "https://github.com/tadasant/zimmer.git",
        branch: "main"
      }.merge(attrs)
    )
  end

  # The composed `github://acme/catalog`, planted where the provider's clone
  # cache expects it. A bare `.git` directory is all `ensureClone` inspects.
  def build_github_catalog!
    dir = File.join(@tmpdir, "home", ".air", "cache", "github", "acme", "catalog", "HEAD")
    FileUtils.mkdir_p(File.join(dir, ".git"))
    write_catalog!(dir, label: "acme", extras: {})
  end

  def build_local_catalog!
    dir = File.join(@tmpdir, "local")
    FileUtils.mkdir_p(dir)
    write_catalog!(
      dir,
      label: "local",
      extras: {
        mcp: {
          "solo-server" => {
            "title" => "Solo Server", "description" => "Only this catalog has it.",
            "type" => "stdio", "command" => "echo", "args" => [ "solo" ],
            "default_in_roots" => [ "solo-root" ]
          }
        },
        skills: {
          "solo-skill" => {
            "id" => "solo-skill", "title" => "Solo Skill", "description" => "Only this catalog has it.",
            "path" => "solo-skill", "category" => "test",
            "references" => [ "shared-ref" ], "default_in_roots" => [ "solo-root" ]
          }
        },
        roots: {
          "solo-root" => {
            "name" => "solo-root", "display_name" => "Solo Root",
            "description" => "Uncontested root, for the backward-compatibility path.",
            "url" => "https://github.com/tadasant/zimmer.git", "default_branch" => "main",
            "user_invocable" => true
          }
        }
      },
      solo_skill_dir: true
    )
    File.write(File.join(dir, "air.json"), JSON.pretty_generate(
      "name" => "composed-local",
      "gitProtocol" => "https",
      "extensions" => [ "@pulsemcp/air-provider-github" ],
      "catalogs" => [ "github://acme/catalog" ],
      "mcp" => [ "./mcp.json" ],
      "skills" => [ "./skills/skills.json" ],
      "roots" => [ "./roots.json" ],
      "references" => [ "./references/references.json" ],
      "hooks" => [ "./hooks/hooks.json" ],
      "plugins" => [ "./plugins/plugins.json" ]
    ))
  end

  # One catalog's six indexes, each carrying the contested short id plus
  # whatever `extras` this side adds.
  def write_catalog!(dir, label:, extras:, solo_skill_dir: false)
    FileUtils.mkdir_p(File.join(dir, "skills", CONTESTED[:skills]))
    File.write(File.join(dir, "skills", CONTESTED[:skills], "SKILL.md"), "# #{label}\n")
    if solo_skill_dir
      FileUtils.mkdir_p(File.join(dir, "skills", "solo-skill"))
      File.write(File.join(dir, "skills", "solo-skill", "SKILL.md"), "# solo\n")
    end
    FileUtils.mkdir_p(File.join(dir, "hooks", CONTESTED[:hooks]))
    File.write(File.join(dir, "hooks", CONTESTED[:hooks], "HOOK.json"), "{}")
    FileUtils.mkdir_p(File.join(dir, "plugins", CONTESTED[:plugins], ".plugin"))
    File.write(File.join(dir, "plugins", CONTESTED[:plugins], ".plugin", "plugin.json"), JSON.generate(
      "name" => CONTESTED[:plugins], "title" => "Shared Plugin (#{label})", "version" => "1.0.0",
      "description" => "Contested plugin from #{label}.", "skills" => [], "mcp_servers" => [], "hooks" => []
    ))
    FileUtils.mkdir_p(File.join(dir, "references"))
    File.write(File.join(dir, "references", "SHARED.md"), "# #{label}\n")

    File.write(File.join(dir, "mcp.json"), JSON.generate({
      CONTESTED[:mcp] => {
        "title" => "Slack (#{label})", "description" => "Contested MCP server from #{label}.",
        "type" => "stdio", "command" => "echo", "args" => [ label ],
        "default_in_roots" => [ CONTESTED[:roots] ]
      }
    }.merge(extras[:mcp] || {})))

    File.write(File.join(dir, "skills", "skills.json"), JSON.generate({
      CONTESTED[:skills] => {
        "id" => CONTESTED[:skills], "title" => "Shared Skill (#{label})",
        "description" => "Contested skill from #{label}.", "path" => CONTESTED[:skills],
        "category" => "test", "references" => [ CONTESTED[:references] ],
        "default_in_roots" => [ CONTESTED[:roots] ]
      }
    }.merge(extras[:skills] || {})))

    File.write(File.join(dir, "roots.json"), JSON.generate({
      CONTESTED[:roots] => {
        "name" => CONTESTED[:roots], "display_name" => "Shared Root (#{label})",
        "description" => "Contested agent root from #{label}.",
        "url" => "https://github.com/#{label}/thing.git", "default_branch" => "main",
        "user_invocable" => true
      }
    }.merge(extras[:roots] || {})))

    File.write(File.join(dir, "references", "references.json"), JSON.generate({
      CONTESTED[:references] => {
        "title" => "Shared Ref (#{label})", "description" => "Contested reference from #{label}.",
        "file" => "SHARED.md"
      }
    }.merge(extras[:references] || {})))

    File.write(File.join(dir, "hooks", "hooks.json"), JSON.generate({
      CONTESTED[:hooks] => {
        "title" => "Shared Hook (#{label})", "description" => "Contested hook from #{label}.",
        "path" => CONTESTED[:hooks]
      }
    }.merge(extras[:hooks] || {})))

    File.write(File.join(dir, "plugins", "plugins.json"), JSON.generate({
      CONTESTED[:plugins] => {
        "description" => "Contested plugin from #{label}.", "path" => "./#{CONTESTED[:plugins]}"
      }
    }.merge(extras[:plugins] || {})))
  end
end
