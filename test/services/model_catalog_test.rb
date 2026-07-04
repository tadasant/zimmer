# frozen_string_literal: true

require "test_helper"

class ModelCatalogTest < ActiveSupport::TestCase
  test "models_for returns the claude_code catalog" do
    models = ModelCatalog.models_for("claude_code")

    assert models.is_a?(Array)
    assert_equal %w[opus sonnet haiku], models.map { |m| m[:id] }
  end

  test "model_ids_for returns just the identifiers" do
    assert_equal %w[opus sonnet haiku], ModelCatalog.model_ids_for("claude_code")
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
    assert_equal %w[gpt-5.5 gpt-5.4 gpt-5.4-mini gpt-5.3-codex gpt-5.2-codex],
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
    assert_equal %w[gpt-5.5 gpt-5.4 gpt-5.4-mini gpt-5.3-codex gpt-5.2-codex],
      ModelCatalog.model_ids_for("codex")
  end

  test "default_for codex is gpt-5.5" do
    assert_equal "gpt-5.5", ModelCatalog.default_for("codex")
  end

  test "valid_model? is true for catalog members and false otherwise" do
    assert ModelCatalog.valid_model?("claude_code", "opus")
    assert ModelCatalog.valid_model?("claude_code", "sonnet")
    refute ModelCatalog.valid_model?("claude_code", "gpt-5")
    refute ModelCatalog.valid_model?("claude_code", nil)
    refute ModelCatalog.valid_model?("claude_code", "")
  end

  test "valid_model? for codex accepts codex models and rejects cross-runtime models" do
    assert ModelCatalog.valid_model?("codex", "gpt-5.5")
    assert ModelCatalog.valid_model?("codex", "gpt-5.2-codex")
    refute ModelCatalog.valid_model?("codex", "opus")
    refute ModelCatalog.valid_model?("codex", "gpt-9")
  end

  test "requires_oauth? reflects the per-model flag" do
    assert ModelCatalog.requires_oauth?("codex", "gpt-5.5")
    refute ModelCatalog.requires_oauth?("codex", "gpt-5.4")
    refute ModelCatalog.requires_oauth?("codex", "gpt-5.4-mini")
  end

  test "requires_oauth? is false for unknown models and runtimes without the flag" do
    refute ModelCatalog.requires_oauth?("codex", "gpt-9")
    refute ModelCatalog.requires_oauth?("claude_code", "opus")
  end
end
