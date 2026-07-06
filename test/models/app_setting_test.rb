# frozen_string_literal: true

require "test_helper"

class AppSettingTest < ActiveSupport::TestCase
  test "blank runtime and model are valid (no override)" do
    setting = AppSetting.new(default_runtime: nil, default_model: nil)
    assert setting.valid?
  end

  test "valid claude_code + opus pairing" do
    assert AppSetting.new(default_runtime: "claude_code", default_model: "opus").valid?
  end

  test "valid codex + gpt-5.5 pairing" do
    assert AppSetting.new(default_runtime: "codex", default_model: "gpt-5.5").valid?
  end

  test "rejects an unregistered runtime" do
    setting = AppSetting.new(default_runtime: "aider", default_model: nil)
    refute setting.valid?
    assert setting.errors[:default_runtime].any?
  end

  test "rejects a Claude Code runtime paired with a GPT model" do
    setting = AppSetting.new(default_runtime: "claude_code", default_model: "gpt-5.5")
    refute setting.valid?
    assert setting.errors[:default_model].any?
  end

  test "rejects a Codex runtime paired with a Claude model" do
    setting = AppSetting.new(default_runtime: "codex", default_model: "opus")
    refute setting.valid?
    assert setting.errors[:default_model].any?
  end

  test "a model with a blank runtime is validated against the default runtime" do
    # Blank runtime resolves to claude_code, so a GPT model is invalid.
    refute AppSetting.new(default_runtime: nil, default_model: "gpt-5.5").valid?
    assert AppSetting.new(default_runtime: nil, default_model: "opus").valid?
  end

  test "resolved_default_model_for returns the configured model when valid for the runtime" do
    setting = AppSetting.new(default_runtime: "codex", default_model: "gpt-5.4")
    assert_equal "gpt-5.4", setting.resolved_default_model_for("codex")
  end

  test "resolved_default_model_for falls back to the runtime catalog default when model is incompatible" do
    setting = AppSetting.new(default_runtime: "codex", default_model: "gpt-5.5")
    # gpt-5.5 is not valid for claude_code → claude_code's catalog default.
    assert_equal ModelCatalog.default_for("claude_code"), setting.resolved_default_model_for("claude_code")
  end

  test "resolved_default_model_for falls back to the catalog default when model is blank" do
    setting = AppSetting.new(default_runtime: "codex", default_model: nil)
    assert_equal ModelCatalog.default_for("codex"), setting.resolved_default_model_for("codex")
  end

  test "current returns a blank, unsaved record when no row exists" do
    AppSetting.delete_all
    setting = AppSetting.current
    refute setting.persisted?
    assert_nil setting.default_runtime
    assert_nil setting.default_model
  end

  test "current returns the persisted singleton row when one exists" do
    AppSetting.delete_all
    AppSetting.create!(default_runtime: "codex", default_model: "gpt-5.5")
    setting = AppSetting.current
    assert setting.persisted?
    assert_equal "codex", setting.default_runtime
    assert_equal "gpt-5.5", setting.default_model
  end

  test "editable returns a persistable record that inserts the first row" do
    AppSetting.delete_all
    setting = AppSetting.editable
    setting.update!(default_runtime: "codex", default_model: "gpt-5.5")
    assert_equal 1, AppSetting.count
  end

  test "only one row may exist" do
    AppSetting.delete_all
    AppSetting.create!(default_runtime: "codex", default_model: "gpt-5.5")
    second = AppSetting.new(default_runtime: "claude_code", default_model: "opus")
    refute second.valid?
    assert second.errors[:base].any?
  end

  test "NULL null-object answers the read interface and defers to the catalog default" do
    assert_nil AppSetting::NULL.default_runtime
    assert_nil AppSetting::NULL.default_model
    assert_equal ModelCatalog.default_for("codex"), AppSetting::NULL.resolved_default_model_for("codex")
  end

  test "extension_states defaults to an empty hash on a fresh record" do
    assert_equal({}, AppSetting.new.extension_states)
  end

  test "an unset extension resolves to the supplied default" do
    setting = AppSetting.new
    refute setting.extension_enabled?("pty_transport")
    assert setting.extension_enabled?("pty_transport", default: true)
  end

  test "NULL null-object reports every extension as off (and honors an explicit default)" do
    assert_equal({}, AppSetting::NULL.extension_states)
    refute AppSetting::NULL.extension_enabled?("pty_transport")
    assert AppSetting::NULL.extension_enabled?("pty_transport", default: true)
  end

  test "class-level extension_enabled? is the default when no row exists" do
    AppSetting.delete_all
    refute AppSetting.extension_enabled?("pty_transport")
    assert AppSetting.extension_enabled?("pty_transport", default: true)
  end

  test "class-level extension_enabled? reflects the persisted state" do
    AppSetting.delete_all
    setting = AppSetting.create!
    setting.set_extension_enabled("pty_transport", true)
    setting.save!
    assert AppSetting.extension_enabled?("pty_transport")

    AppSetting.current.tap { |s| s.set_extension_enabled("pty_transport", false); s.save! }
    refute AppSetting.extension_enabled?("pty_transport")
  end

  test "set_extension_enabled touches only the named key" do
    setting = AppSetting.new
    setting.set_extension_enabled("pty_transport", true)
    setting.set_extension_enabled("mcp_tool_search", false)
    assert_equal({ "pty_transport" => true, "mcp_tool_search" => false }, setting.extension_states)

    setting.set_extension_enabled("mcp_tool_search", true)
    assert setting.extension_enabled?("pty_transport"), "unrelated key must be preserved"
    assert setting.extension_enabled?("mcp_tool_search")
  end

  test "extension_enabled? coerces stored values through the boolean type" do
    setting = AppSetting.new
    setting.extension_states = { "pty_transport" => "1", "mcp_tool_search" => "0" }
    assert setting.extension_enabled?("pty_transport")
    refute setting.extension_enabled?("mcp_tool_search")
  end

  test "extension_enabled? returns the default when the extension_states column is absent" do
    # Simulates new code booting against a schema that predates the column's
    # migration: the lookup must degrade to the default instead of raising, so
    # the session-spawn hot path stays alive during that deploy window.
    setting = AppSetting.new
    setting.define_singleton_method(:has_attribute?) do |name|
      name.to_sym == :extension_states ? false : super(name)
    end
    refute setting.extension_enabled?("pty_transport")
    assert setting.extension_enabled?("pty_transport", default: true)
  end
end
