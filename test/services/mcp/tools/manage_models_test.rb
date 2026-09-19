# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class Mcp::Tools::ManageModelsTest < ActiveSupport::TestCase
  UNLISTED = ModelCatalogCliCheck::Result.new(listed: false, cli_version: "0.146.0", note: "Not in codex 0.146.0's model list.")

  setup do
    @tool = Mcp::Tools::ManageModels.new(context: Mcp::Context.new(tool_groups: "sessions"))
  end

  test "is served to a sessions connection but not to self_session or a readonly one" do
    assert_includes Mcp::Registry.tools_for(%w[sessions]).map(&:tool_name), "manage_models"
    refute_includes Mcp::Registry.tools_for(%w[self_session]).map(&:tool_name), "manage_models"
    refute_includes Mcp::Registry.tools_for(%w[sessions_readonly]).map(&:tool_name), "manage_models"
  end

  test "list shows built-in models per runtime" do
    output = @tool.call("action" => "list")

    assert_includes output, "### Claude Code (`claude_code`)"
    assert_includes output, "- `opus` (default, built in)"
    assert_includes output, "`gpt-5.6-terra`"
  end

  test "add then list shows the model with its CLI check, and start_session validation accepts it" do
    output = @tool.call("action" => "add", "runtime" => "claude_code", "model_id" => "opus[1m]")

    assert_includes output, "## Model Added"
    assert_includes output, "not checked"
    assert_equal "mcp", ModelCatalogEntry.find_by!(model_id: "opus[1m]").added_via
    assert ModelCatalog.valid_model?("claude_code", "opus[1m]")

    listed = @tool.call("action" => "list")
    assert_includes listed, "- `opus[1m]` (added)"
    assert_includes listed, "CLI check: not checked"
  end

  test "add refuses an unlisted id and says how to add it anyway" do
    ModelCatalogCliCheck.stubs(:check).returns(UNLISTED)

    error = assert_raises(Mcp::ToolError) do
      @tool.call("action" => "add", "runtime" => "codex", "model_id" => "gpt-9")
    end
    assert_match(/Pass allow_unlisted: true/, error.message)

    output = @tool.call("action" => "add", "runtime" => "codex", "model_id" => "gpt-9", "allow_unlisted" => true)
    assert_includes output, "NOT LISTED"
  end

  test "add surfaces validation errors" do
    error = assert_raises(Mcp::ToolError) do
      @tool.call("action" => "add", "runtime" => "pi", "model_id" => "bare")
    end
    assert_match(/provider-qualified/, error.message)
  end

  test "remove deletes an added model and explains built-in and unknown ones" do
    ModelCatalogEntry.add(runtime: "claude_code", model_id: "opus[1m]", added_via: "mcp")

    assert_match(/Removed/, @tool.call("action" => "remove", "runtime" => "claude_code", "model_id" => "opus[1m]"))
    refute ModelCatalogEntry.exists?(model_id: "opus[1m]")

    built_in = assert_raises(Mcp::ToolError) { @tool.call("action" => "remove", "runtime" => "claude_code", "model_id" => "opus") }
    assert_match(/built-in/, built_in.message)

    unknown = assert_raises(Mcp::ToolError) { @tool.call("action" => "remove", "runtime" => "codex", "model_id" => "nope") }
    assert_match(/No added codex model/, unknown.message)
  end

  test "remove is refused while the session default names the model" do
    ModelCatalogEntry.add(runtime: "claude_code", model_id: "opus[1m]", added_via: "mcp")
    AppSetting.editable.update!(default_runtime: "claude_code", default_model: "opus[1m]")

    error = assert_raises(Mcp::ToolError) do
      @tool.call("action" => "remove", "runtime" => "claude_code", "model_id" => "opus[1m]")
    end
    assert_match(/session default/, error.message)
  end
end
