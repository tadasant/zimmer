# frozen_string_literal: true

require "test_helper"
require "prism"

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
    assert_equal %w[gpt-5.6-sol gpt-5.6-terra gpt-5.6-luna gpt-5.5 gpt-5.4 gpt-5.4-mini gpt-5.3-codex gpt-5.2-codex],
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
    assert_equal %w[gpt-5.6-sol gpt-5.6-terra gpt-5.6-luna gpt-5.5 gpt-5.4 gpt-5.4-mini gpt-5.3-codex gpt-5.2-codex],
      ModelCatalog.model_ids_for("codex")
  end

  test "default_for codex is gpt-5.6-terra" do
    assert_equal "gpt-5.6-terra", ModelCatalog.default_for("codex")
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
    assert ModelCatalog.valid_model?("codex", "gpt-5.6-sol")
    assert ModelCatalog.valid_model?("codex", "gpt-5.6-terra")
    assert ModelCatalog.valid_model?("codex", "gpt-5.6-luna")
    assert ModelCatalog.valid_model?("codex", "gpt-5.5")
    assert ModelCatalog.valid_model?("codex", "gpt-5.2-codex")
    refute ModelCatalog.valid_model?("codex", "opus")
    refute ModelCatalog.valid_model?("codex", "fable")
    refute ModelCatalog.valid_model?("codex", "gpt-9")
  end

  test "requires_oauth? reflects the per-model flag" do
    assert ModelCatalog.requires_oauth?("codex", "gpt-5.6-sol")
    assert ModelCatalog.requires_oauth?("codex", "gpt-5.6-terra")
    assert ModelCatalog.requires_oauth?("codex", "gpt-5.6-luna")
    assert ModelCatalog.requires_oauth?("codex", "gpt-5.5")
    refute ModelCatalog.requires_oauth?("codex", "gpt-5.4")
    refute ModelCatalog.requires_oauth?("codex", "gpt-5.4-mini")
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
