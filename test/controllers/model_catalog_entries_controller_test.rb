# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class ModelCatalogEntriesControllerTest < ActionDispatch::IntegrationTest
  UNLISTED = ModelCatalogCliCheck::Result.new(listed: false, cli_version: "0.146.0", note: "Not in codex 0.146.0's model list.")
  LISTED = ModelCatalogCliCheck::Result.new(listed: true, cli_version: "0.146.0", note: "Listed by codex 0.146.0.")

  test "index lists every runtime's built-in models and links from Settings" do
    get settings_path
    assert_select "a[href=?]", model_catalog_entries_path

    get model_catalog_entries_path

    assert_response :success
    ModelCatalog.runtimes.each { |runtime| assert_select "#models-#{runtime}" }
    assert_select "#models-codex", text: /gpt-5.6-terra/
  end

  test "create adds a model and it shows up on the new-session form" do
    ModelCatalogCliCheck.stubs(:check).returns(LISTED)

    post model_catalog_entries_path, params: { model_catalog_entry: { runtime: "codex", model_id: "gpt-5.7", label: "", requires_oauth: "0", allow_unlisted: "0" } }

    assert_redirected_to model_catalog_entries_path
    assert_match(/Added gpt-5.7/, flash[:notice])
    entry = ModelCatalogEntry.find_by!(runtime: "codex", model_id: "gpt-5.7")
    assert_equal "web_ui", entry.added_via

    follow_redirect!
    assert_select "#models-codex", text: /CLI lists it/

    get new_session_path
    assert_includes response.body, "gpt-5.7"
  end

  test "create refuses an unlisted id and re-renders with the CLI's note, until allowed" do
    ModelCatalogCliCheck.stubs(:check).returns(UNLISTED)
    params = { model_catalog_entry: { runtime: "codex", model_id: "gpt-9", allow_unlisted: "0" } }

    post model_catalog_entries_path, params: params

    assert_response :unprocessable_entity
    assert_select "#model-catalog-entry-errors", text: /Not in codex 0.146.0's model list/
    assert_select "#model_catalog_entry_model_id[value=?]", "gpt-9"
    refute ModelCatalogEntry.exists?(model_id: "gpt-9")

    params[:model_catalog_entry][:allow_unlisted] = "1"
    post model_catalog_entries_path, params: params

    assert_redirected_to model_catalog_entries_path
    follow_redirect!
    assert_select "#models-codex", text: /Not in the CLI's list/
  end

  test "create shows validation errors" do
    post model_catalog_entries_path, params: { model_catalog_entry: { runtime: "pi", model_id: "no-provider" } }

    assert_response :unprocessable_entity
    assert_select "#model-catalog-entry-errors", text: /provider-qualified/
  end

  test "destroy removes an added model" do
    entry = ModelCatalogEntry.add(runtime: "claude_code", model_id: "opus[1m]", added_via: "web_ui")

    delete model_catalog_entry_path(entry)

    assert_redirected_to model_catalog_entries_path
    refute ModelCatalogEntry.exists?(entry.id)
  end

  test "destroy is refused while the session default names the model" do
    entry = ModelCatalogEntry.add(runtime: "claude_code", model_id: "opus[1m]", added_via: "web_ui")
    AppSetting.editable.update!(default_runtime: "claude_code", default_model: "opus[1m]")

    delete model_catalog_entry_path(entry)

    assert_redirected_to model_catalog_entries_path
    assert_match(/session default/, flash[:alert])
    assert ModelCatalogEntry.exists?(entry.id)
  end
end
