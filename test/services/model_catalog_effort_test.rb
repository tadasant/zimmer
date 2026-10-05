require "test_helper"

# The reasoning-effort half of ModelCatalog: which `config.effort` levels each
# model takes, what it runs at when none is set, and the refusal for anything
# else. The levels and defaults mirror the model table in the installed Claude
# Code CLI and https://platform.claude.com/docs/en/build-with-claude/effort.
class ModelCatalogEffortTest < ActiveSupport::TestCase
  ALL_LEVELS = %w[low medium high xhigh max].freeze

  test "Claude Code's levels are the CLI's --effort values, lowest to highest" do
    assert_equal ALL_LEVELS, ModelCatalog::CLAUDE_CODE_EFFORT_LEVELS
  end

  test "opus, sonnet and fable take every level; haiku takes none" do
    %w[opus sonnet fable].each do |model|
      assert_equal ALL_LEVELS, ModelCatalog.effort_levels_for("claude_code", model), model
    end
    assert_equal [], ModelCatalog.effort_levels_for("claude_code", "haiku")
  end

  test "each model's default is Anthropic's recommended level for it" do
    assert_equal "medium", ModelCatalog.default_effort_for("claude_code", "opus")
    assert_equal "medium", ModelCatalog.default_effort_for("claude_code", "sonnet")
    assert_equal "high", ModelCatalog.default_effort_for("claude_code", "fable")
    assert_nil ModelCatalog.default_effort_for("claude_code", "haiku")
  end

  test "Codex, Pi and unknown models take no effort setting" do
    assert_equal [], ModelCatalog.effort_levels_for("codex", ModelCatalog.default_for("codex"))
    assert_equal [], ModelCatalog.effort_levels_for("pi", ModelCatalog.default_for("pi"))
    assert_equal [], ModelCatalog.effort_levels_for("claude_code", "not-a-model")
  end

  test "effort_error accepts a supported level and a blank one" do
    assert_nil ModelCatalog.effort_error("claude_code", "fable", "xhigh")
    assert_nil ModelCatalog.effort_error("claude_code", "haiku", nil)
    assert_nil ModelCatalog.effort_error("codex", "gpt-5.6-terra", "")
  end

  test "effort_error names the valid levels and the default for an unknown level" do
    message = ModelCatalog.effort_error("claude_code", "fable", "extra-high")

    assert_match(/"extra-high" is not valid for model "fable"/, message)
    assert_match(/low, medium, high, xhigh, max/, message)
    assert_match(/default: high/, message)
  end

  test "effort_error on a model without effort names the models that have it" do
    message = ModelCatalog.effort_error("claude_code", "haiku", "high")

    assert_match(/"haiku" does not support an effort setting/, message)
    assert_match(/opus, sonnet, fable/, message)
  end

  test "effort_error on a runtime without effort says so" do
    assert_match(/not supported on the codex runtime/, ModelCatalog.effort_error("codex", "gpt-5.6-terra", "high"))
    assert_match(/not supported on the pi runtime/, ModelCatalog.effort_error("pi", ModelCatalog.default_for("pi"), "high"))
  end

  test "effort_options_by_runtime lists only the models that take a level" do
    options = ModelCatalog.effort_options_by_runtime

    assert_equal %w[opus sonnet fable], options["claude_code"].keys
    assert_equal({ levels: ALL_LEVELS, default: "high" }, options["claude_code"]["fable"])
    assert_equal({}, options["codex"])
    assert_equal({}, options["pi"])
  end
end
