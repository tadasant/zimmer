# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class ModelCatalogEntryTest < ActiveSupport::TestCase
  LISTED = ModelCatalogCliCheck::Result.new(listed: true, cli_version: "0.146.0", note: "Listed by codex 0.146.0.")
  UNLISTED = ModelCatalogCliCheck::Result.new(listed: false, cli_version: "0.146.0", note: "Not in codex 0.146.0's model list.")

  def add(**overrides)
    ModelCatalogEntry.add(runtime: "codex", model_id: "gpt-5.7", added_via: "api", **overrides)
  end

  test "add saves a model the CLI lists and stores the check" do
    ModelCatalogCliCheck.expects(:check).with("codex", "gpt-5.7").returns(LISTED)

    entry = add(label: "gpt-5.7 (new)", requires_oauth: "1")

    assert entry.persisted?, entry.errors.full_messages.inspect
    assert_equal true, entry.cli_listed
    assert_equal "0.146.0", entry.cli_version
    assert_equal "Listed by codex 0.146.0.", entry.cli_note
    assert entry.requires_oauth
    assert_equal "gpt-5.7 (new)", entry.display_label
  end

  test "add refuses an id the CLI does not list, with the CLI's note" do
    ModelCatalogCliCheck.stubs(:check).returns(UNLISTED)

    entry = add

    refute entry.persisted?
    assert entry.errors.of_kind?(:model_id, :unlisted)
    assert_includes entry.errors.full_messages.join, "Not in codex 0.146.0's model list."
    assert_equal false, entry.cli_listed
  end

  test "add saves an unlisted id when the caller allows it" do
    ModelCatalogCliCheck.stubs(:check).returns(UNLISTED)

    entry = add(allow_unlisted: "true")

    assert entry.persisted?
    assert entry.unlisted?
  end

  test "add saves an unchecked id without asking for allow_unlisted" do
    entry = ModelCatalogEntry.add(runtime: "claude_code", model_id: "opus[1m]", added_via: "mcp")

    assert entry.persisted?, entry.errors.full_messages.inspect
    assert_nil entry.cli_listed
    assert_match(/no model list/, entry.cli_note)
  end

  test "add does not run the CLI check for an invalid id" do
    ModelCatalogCliCheck.expects(:check).never

    refute add(model_id: "has space").persisted?
  end

  test "rejects a runtime with no catalog" do
    entry = ModelCatalogEntry.new(runtime: "aider", model_id: "x", added_via: "api")
    refute entry.valid?
    assert_includes entry.errors[:runtime].join, "has no model catalog"
  end

  test "rejects an id that is already built in" do
    entry = ModelCatalogEntry.new(runtime: "codex", model_id: "gpt-5.5", added_via: "api")
    refute entry.valid?
    assert_includes entry.errors[:model_id].join, "already a built-in"
  end

  test "rejects a duplicate added id for the same runtime but not another runtime" do
    ModelCatalogCliCheck.stubs(:check).returns(LISTED)
    assert add.persisted?

    refute add.persisted?
    assert ModelCatalogEntry.new(runtime: "pi", model_id: "openrouter/gpt-5.7", added_via: "api").valid?
  end

  test "rejects flag-like, whitespace and over-long ids" do
    [ "-m", "--model", "gpt 5", "a" * 201, "" ].each do |id|
      refute ModelCatalogEntry.new(runtime: "codex", model_id: id, added_via: "api").valid?, id.inspect
    end
  end

  test "rejects a dated snapshot on any runtime" do
    refute ModelCatalogEntry.new(runtime: "codex", model_id: "gpt-5.7-20260901", added_via: "api").valid?
    refute ModelCatalogEntry.new(runtime: "pi", model_id: "vertex/model@20260901", added_via: "api").valid?
  end

  test "rejects a concrete Claude version in the Claude Code catalog" do
    entry = ModelCatalogEntry.new(runtime: "claude_code", model_id: "claude-opus-9", added_via: "api")
    refute entry.valid?
    assert_includes entry.errors[:model_id].join, "pins a Claude version"
  end

  test "requires a provider-qualified Pi id" do
    refute ModelCatalogEntry.new(runtime: "pi", model_id: "gpt-5.7", added_via: "api").valid?
    assert ModelCatalogEntry.new(runtime: "pi", model_id: "openrouter/openai/gpt-5.7", added_via: "api").valid?
  end

  test "rejects an unknown added_via" do
    refute ModelCatalogEntry.new(runtime: "codex", model_id: "gpt-5.7", added_via: "shell").valid?
  end

  test "destroy is refused while the session default names the model" do
    ModelCatalogCliCheck.stubs(:check).returns(LISTED)
    entry = add
    AppSetting.editable.update!(default_runtime: "codex", default_model: "gpt-5.7")

    refute entry.destroy
    assert_match(/session default/, entry.destroy_refusal)
    assert ModelCatalogEntry.exists?(entry.id)
  end

  test "destroy is refused while the categorization model names the model" do
    entry = ModelCatalogEntry.add(runtime: "claude_code", model_id: "opus[1m]", added_via: "api")
    AppSetting.editable.update!(category_inference_model: "opus[1m]")

    refute entry.destroy
    assert_match(/categorization model/, entry.destroy_refusal)
  end

  test "destroy succeeds when nothing names the model" do
    ModelCatalogCliCheck.stubs(:check).returns(LISTED)
    entry = add

    assert entry.destroy
    refute ModelCatalogEntry.exists?(entry.id)
  end

  test "shadowed_by_built_in? is true for a row a later deploy made built in" do
    entry = ModelCatalogEntry.new(runtime: "codex", model_id: "gpt-5.5", added_via: "api")
    entry.save!(validate: false)

    assert entry.shadowed_by_built_in?
  end
end
