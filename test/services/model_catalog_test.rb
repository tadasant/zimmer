# frozen_string_literal: true

require "test_helper"
require "prism"
require "mocha/minitest"

class ModelCatalogTest < ActiveSupport::TestCase
  test "models_for returns the claude_code catalog" do
    models = ModelCatalog.models_for("claude_code")

    assert models.is_a?(Array)
    assert_equal %w[opus sonnet haiku fable], models.map { |m| m[:id] }
  end

  test "model_ids_for returns just the identifiers" do
    assert_equal %w[opus sonnet haiku fable], ModelCatalog.model_ids_for("claude_code")
  end

  test "default_for returns the model flagged as default" do
    assert_equal "opus", ModelCatalog.default_for("claude_code")
  end

  test "blank runtime resolves to the default runtime's catalog" do
    assert_equal ModelCatalog.model_ids_for("claude_code"), ModelCatalog.model_ids_for(nil)
    assert_equal ModelCatalog.model_ids_for("claude_code"), ModelCatalog.model_ids_for("")
  end

  test "runtime with its own catalog entry resolves to itself, not the default" do
    # A runtime is reachable as soon as it has a MODELS entry, even before
    # RuntimeRegistry registers its implementation bundle.
    assert_equal %w[sol terra luna],
      ModelCatalog.model_ids_for("codex")
    refute_equal ModelCatalog.model_ids_for("claude_code"), ModelCatalog.model_ids_for("codex")
  end

  test "unknown runtime falls back to the default runtime's catalog" do
    # "aider" is not a registered runtime and has no catalog entry, so it
    # resolves to the default runtime's catalog.
    assert_equal ModelCatalog.model_ids_for("claude_code"), ModelCatalog.model_ids_for("aider")
    assert_equal "opus", ModelCatalog.default_for("aider")
  end

  test "models_for returns the codex catalog" do
    assert_equal %w[sol terra luna],
      ModelCatalog.model_ids_for("codex")
  end

  test "default_for codex is terra" do
    assert_equal "terra", ModelCatalog.default_for("codex")
  end

  test "valid_model? is true for catalog members and false otherwise" do
    assert ModelCatalog.valid_model?("claude_code", "opus")
    assert ModelCatalog.valid_model?("claude_code", "sonnet")
    assert ModelCatalog.valid_model?("claude_code", "fable")
    refute ModelCatalog.valid_model?("claude_code", "gpt-5")
    refute ModelCatalog.valid_model?("claude_code", nil)
    refute ModelCatalog.valid_model?("claude_code", "")
  end

  test "valid_model? for codex accepts codex models and rejects cross-runtime models" do
    assert ModelCatalog.valid_model?("codex", "sol")
    assert ModelCatalog.valid_model?("codex", "terra")
    assert ModelCatalog.valid_model?("codex", "luna")
    refute ModelCatalog.valid_model?("codex", "opus")
    refute ModelCatalog.valid_model?("codex", "fable")
    refute ModelCatalog.valid_model?("codex", "gpt-9")
  end

  test "requires_oauth? reflects the per-model flag" do
    assert ModelCatalog.requires_oauth?("codex", "sol")
    assert ModelCatalog.requires_oauth?("codex", "terra")
    assert ModelCatalog.requires_oauth?("codex", "luna")
    refute ModelCatalog.requires_oauth?("pi", ModelCatalog.default_for("pi"))
  end

  test "requires_oauth? is false for unknown models and runtimes without the flag" do
    refute ModelCatalog.requires_oauth?("codex", "gpt-9")
    refute ModelCatalog.requires_oauth?("claude_code", "opus")
    refute ModelCatalog.requires_oauth?("claude_code", "fable")
  end

  test "messages_api_id_for returns the Messages API floating alias for haiku" do
    assert_equal "claude-haiku-4-5", ModelCatalog.messages_api_id_for("haiku")
    assert_equal "claude-haiku-4-5", ModelCatalog.messages_api_id_for(:haiku)
  end

  test "messages_api_id_for raises for a model with no Messages API id or no entry" do
    assert_raises(KeyError) { ModelCatalog.messages_api_id_for("opus") }
    assert_raises(KeyError) { ModelCatalog.messages_api_id_for("claude-haiku-4-5") }
    assert_raises(KeyError) { ModelCatalog.messages_api_id_for(nil) }
  end

  # --- Models added at runtime (ModelCatalogEntry, #85) -----------------------

  def insert_entry(runtime, model_id, **attrs)
    ModelCatalogEntry.new(runtime: runtime, model_id: model_id, added_via: "api", **attrs).tap { |e| e.save!(validate: false) }
  end

  test "added models follow the built-in ones and validate like them" do
    insert_entry("codex", "gpt-5.7", label: "gpt-5.7 (new)", requires_oauth: true, cli_listed: false, cli_version: "0.146.0", cli_note: "Not listed.")

    models = ModelCatalog.models_for("codex")
    added = models.last

    assert_equal "gpt-5.7", added[:id]
    assert_equal "added", added[:source]
    assert_equal "gpt-5.7 (new)", added[:label]
    assert_equal false, added[:cli_listed]
    assert_equal "0.146.0", added[:cli_version]
    assert models.first(ModelCatalog::MODELS["codex"].size).all? { |m| m[:source] == "built_in" }
    assert ModelCatalog.valid_model?("codex", "gpt-5.7")
    assert ModelCatalog.requires_oauth?("codex", "gpt-5.7")
    refute ModelCatalog.valid_model?("claude_code", "gpt-5.7")
  end

  test "an added model never becomes the fallback default or the probe id" do
    insert_entry("claude_code", "opus[1m]")

    assert_equal "opus", ModelCatalog.default_for("claude_code")
    assert_equal "claude-haiku-4-5", ModelCatalog.messages_api_id_for("haiku")
    assert_raises(KeyError) { ModelCatalog.messages_api_id_for("opus[1m]") }
  end

  test "an added row a deploy made built in is skipped, so the built-in entry wins" do
    insert_entry("codex", "luna", label: "shadow")

    ids = ModelCatalog.model_ids_for("codex")
    assert_equal 1, ids.count("luna")
    assert_equal "built_in", ModelCatalog.models_for("codex").find { |m| m[:id] == "luna" }[:source]
  end

  test "an unreadable added-models table degrades to the built-in list" do
    ModelCatalogEntry.stubs(:where).raises(ActiveRecord::StatementInvalid, "relation does not exist")

    assert_equal %w[opus sonnet haiku fable], ModelCatalog.model_ids_for("claude_code")
  end

  # The batch read the Quick Router's harness picker uses. It must agree with the
  # per-runtime read exactly — a picker offering one list while the server
  # validates against another is the bug it exists to avoid. Both are built by the
  # same #merge_added, and these pin that they stay that way.
  test "models_by_runtime agrees with models_for on every runtime" do
    insert_entry("claude_code", "opus[1m]")
    insert_entry("codex", "gpt-5.7")
    runtimes = RuntimeRegistry.registered_runtimes

    by_runtime = ModelCatalog.models_by_runtime(runtimes)

    assert_equal runtimes, by_runtime.keys
    runtimes.each { |runtime| assert_equal ModelCatalog.models_for(runtime), by_runtime[runtime] }
  end

  # The two branches a single added row per runtime cannot exercise: the built-in
  # dedup, and the ordering of several added rows within one runtime.
  test "models_by_runtime drops an added row a deploy made built in, like models_for" do
    insert_entry("codex", "luna", label: "shadow")

    models = ModelCatalog.models_by_runtime(%w[codex])["codex"]
    assert_equal 1, models.count { |m| m[:id] == "luna" }
    assert_equal "built_in", models.find { |m| m[:id] == "luna" }[:source]
    assert_equal ModelCatalog.models_for("codex"), models
  end

  test "models_by_runtime orders several added rows for one runtime by created_at" do
    insert_entry("codex", "gpt-5.9", created_at: 2.days.ago)
    insert_entry("codex", "gpt-5.7", created_at: 3.days.ago)
    insert_entry("claude_code", "opus[1m]", created_at: 1.day.ago)

    added = ModelCatalog.models_by_runtime(%w[codex])["codex"].select { |m| m[:source] == "added" }
    assert_equal %w[gpt-5.7 gpt-5.9], added.map { |m| m[:id] }
    assert_equal ModelCatalog.models_for("codex"), ModelCatalog.models_by_runtime(%w[codex])["codex"]
  end

  test "models_by_runtime reads the added-models table once for the whole map" do
    insert_entry("codex", "gpt-5.7")
    runtimes = RuntimeRegistry.registered_runtimes
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      statements << payload[:sql] if payload[:sql].include?("model_catalog_entries")
    end

    ModelCatalog.models_by_runtime(runtimes)

    assert_equal 1, statements.size, "expected one read, got:\n#{statements.join("\n")}"
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  test "models_by_runtime degrades to the built-in lists when the added-models table is unreadable" do
    ModelCatalogEntry.stubs(:order).raises(ActiveRecord::StatementInvalid, "relation does not exist")

    assert_equal %w[opus sonnet haiku fable],
      ModelCatalog.models_by_runtime(%w[claude_code])["claude_code"].map { |m| m[:id] }
  end

  # A dated snapshot silently outlives the model it names (#85). Nothing in the
  # catalog, on any runtime, is one — in Anthropic's `-YYYYMMDD` form or
  # Vertex's `@YYYYMMDD`.
  test "no catalog id is a dated model snapshot" do
    ids = ModelCatalog::MODELS.values.flatten.flat_map { |m| [ m[:id], m[:messages_api_id] ] }.compact

    offenders = ids.grep(/[-@]\d{8}\z/)
    assert_empty offenders, "ModelCatalog must hold floating aliases, not dated snapshots"
  end

  test "claude_code ids are floating CLI aliases the model-pin audit accepts" do
    ModelCatalog.model_ids_for("claude_code").each do |id|
      refute ClaudeModelConfigurationAudit.concrete_model?(id),
        "claude_code id #{id.inspect} pins a model version; use the bare alias"
    end
  end

  # The Codex and Pi counterpart to the test above: their built-ins are model
  # families (`terra`) and OpenRouter's floating `~…-latest` aliases, never a
  # versioned id, so a new release needs no change in Zimmer. A pin that has to
  # stay is an added model, not a built-in.
  test "codex built-in ids are version-free model families" do
    ModelCatalog::MODELS.fetch("codex").each do |model|
      assert_match(/\A[a-z]+\z/, model[:id], "codex id #{model[:id].inspect} pins a version; use the family name")
    end
  end

  test "pi built-in ids are OpenRouter floating aliases with no version number" do
    ModelCatalog::MODELS.fetch("pi").each do |model|
      assert_match(%r{\Aopenrouter/~[a-z0-9-]+/[a-z-]+-latest\z}, model[:id],
        "pi id #{model[:id].inspect} is not a version-free `openrouter/~<vendor>/<family>-latest` alias")
    end
  end

  test "legacy ids stay valid without being offered, and map onto a built-in" do
    ModelCatalog::LEGACY_MODEL_ALIASES.each do |runtime, aliases|
      offered = ModelCatalog.model_ids_for(runtime)
      aliases.each do |legacy, replacement|
        assert ModelCatalog.valid_model?(runtime, legacy), "#{legacy} must stay valid for #{runtime}"
        refute_includes offered, legacy, "#{legacy} must not be offered in a #{runtime} picker"
        assert_includes offered, replacement, "#{legacy} must map onto a #{runtime} built-in" if replacement
      end
    end
  end

  test "canonical_model_id moves a legacy id onto its replacement and leaves everything else alone" do
    assert_equal "terra", ModelCatalog.canonical_model_id("codex", "gpt-5.6-terra")
    assert_equal "luna", ModelCatalog.canonical_model_id("codex", "gpt-5.4-mini")
    assert_equal "terra", ModelCatalog.canonical_model_id("codex", "terra")
    assert_equal "gpt-9", ModelCatalog.canonical_model_id("codex", "gpt-9")
    assert_nil ModelCatalog.canonical_model_id("codex", nil)
    assert_equal "openrouter/~anthropic/claude-sonnet-latest",
      ModelCatalog.canonical_model_id("pi", "openrouter/anthropic/claude-sonnet-4.6")
    assert_equal "openrouter/openai/gpt-5.4", ModelCatalog.canonical_model_id("pi", "openrouter/openai/gpt-5.4")
  end

  test "an operator-added model with a legacy id is a deliberate pin" do
    insert_entry("codex", "gpt-5.5", label: "pinned")

    assert_equal "gpt-5.5", ModelCatalog.canonical_model_id("codex", "gpt-5.5")
    assert_nil ModelCatalog.codex_family_for("gpt-5.5")
  end

  test "codex_family_for names the family a codex id launches as" do
    assert_equal "terra", ModelCatalog.codex_family_for("terra")
    assert_equal "sol", ModelCatalog.codex_family_for("gpt-5.6-sol")
    assert_nil ModelCatalog.codex_family_for("gpt-9")
  end

  test "each messages_api_id is a Messages API id for its own model, not the bare CLI alias" do
    entries = ModelCatalog.models_for("claude_code").select { |m| m[:messages_api_id] }
    assert entries.any?, "the quota probe needs at least one claude_code entry with a messages_api_id"

    entries.each do |entry|
      api_id = entry[:messages_api_id]
      assert_match(/\Aclaude-#{Regexp.escape(entry[:id])}-\d/, api_id,
        "#{entry[:id]}'s messages_api_id must be claude-#{entry[:id]}-<version>")
      refute_includes ModelCatalog.model_ids_for("claude_code"), api_id
    end
  end

  # ClaudeModelConfigurationAudit only reads ANTHROPIC_MODEL and settings.json.
  # This extends its rule to the code: a Claude model version the audit would
  # call concrete — bare (`claude-haiku-4-5`), provider-qualified
  # (`openrouter/anthropic/claude-opus-4.6`) or Bedrock-style
  # (`us.anthropic.claude-…`) — lives in ModelCatalog and nowhere else, so every
  # model pin is where the tests above can see it (#85). It checks each token of
  # every string, symbol and backtick literal in the Ruby under app/, config/
  # and lib/, so an id inside a tool description or a command line counts too.
  # Comments, ERB, YAML and JavaScript are not scanned.
  test "no Claude model-version literal lives outside ModelCatalog" do
    catalog_path = Rails.root.join("app/services/model_catalog.rb").to_s

    offenders = Dir[Rails.root.join("{app,config,lib}/**/*.{rb,rake}").to_s].sort.flat_map do |path|
      next [] if path == catalog_path

      StringLiteralCollector.collect(path).flat_map do |value, line|
        value.scan(%r{[\w./@:-]+})
          .select { |token| token.split(%r{[/.]}).any? { |segment| ClaudeModelConfigurationAudit.concrete_model?(segment) } }
          .map { |token| "#{path.delete_prefix("#{Rails.root}/")}:#{line} #{token.inspect}" }
      end
    end

    assert_empty offenders, "Claude model ids belong in ModelCatalog; look them up from there"
  end

  class StringLiteralCollector < Prism::Visitor
    def self.collect(path)
      new.tap { |collector| Prism.parse_file(path).value.accept(collector) }.strings
    end

    attr_reader :strings

    def initialize
      @strings = []
      super
    end

    def visit_string_node(node)
      @strings << [ node.unescaped, node.location.start_line ]
      super
    end

    def visit_symbol_node(node)
      @strings << [ node.unescaped, node.location.start_line ]
      super
    end

    def visit_x_string_node(node)
      @strings << [ node.unescaped, node.location.start_line ]
      super
    end
  end
end
