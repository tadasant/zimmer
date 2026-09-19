# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class Api::V1::ModelCatalogEntriesControllerTest < ActionDispatch::IntegrationTest
  UNLISTED = ModelCatalogCliCheck::Result.new(listed: false, cli_version: "0.84.4", note: "Not in pi 0.84.4's model list for openrouter.")

  setup do
    @valid_api_key = "test_api_key_12345"
    @headers = { "X-API-Key" => @valid_api_key }
    ENV["API_KEYS"] = @valid_api_key
  end

  teardown do
    ENV.delete("API_KEYS")
  end

  test "requires an API key" do
    get api_v1_model_catalog_entries_path
    assert_response :unauthorized
  end

  test "create adds a model, and configs lists it as added" do
    post api_v1_model_catalog_entries_path, params: { runtime: "claude_code", model_id: "opus[1m]", label: "opus 1M" }, headers: @headers

    assert_response :created
    body = response.parsed_body["model_catalog_entry"]
    assert_equal "opus[1m]", body["model_id"]
    assert_equal "opus 1M", body["label"]
    assert_nil body["cli_listed"]
    assert_equal "api", body["added_via"]
    assert_equal false, body["shadowed_by_built_in"]

    get api_v1_model_catalog_entries_path, headers: @headers
    assert_equal [ "opus[1m]" ], response.parsed_body["model_catalog_entries"].map { |e| e["model_id"] }

    get api_v1_configs_path, headers: @headers
    models = response.parsed_body.dig("runtime_models", "claude_code", "models")
    assert_equal "built_in", models.find { |m| m["id"] == "opus" }["source"]
    added = models.find { |m| m["id"] == "opus[1m]" }
    assert_equal "added", added["source"]
    assert added.key?("cli_note")
  end

  test "create refuses an unlisted id with a distinct error, and allow_unlisted lifts it" do
    ModelCatalogCliCheck.stubs(:check).returns(UNLISTED)
    params = { runtime: "pi", model_id: "openrouter/openai/gpt-9" }

    post api_v1_model_catalog_entries_path, params: params, headers: @headers

    assert_response :unprocessable_entity
    assert_equal "Model not listed by CLI", response.parsed_body["error"]
    assert_equal false, response.parsed_body["cli_listed"]
    assert_equal "0.84.4", response.parsed_body["cli_version"]

    post api_v1_model_catalog_entries_path, params: params.merge(allow_unlisted: true), headers: @headers

    assert_response :created
    assert_equal false, response.parsed_body.dig("model_catalog_entry", "cli_listed")
  end

  test "create rejects an invalid model" do
    post api_v1_model_catalog_entries_path, params: { runtime: "codex", model_id: "gpt-5.5" }, headers: @headers

    assert_response :unprocessable_entity
    assert_equal "Validation failed", response.parsed_body["error"]
    assert_match(/already a built-in/, response.parsed_body["message"])
  end

  test "destroy removes an added model, and refuses one the session default names" do
    entry = ModelCatalogEntry.add(runtime: "claude_code", model_id: "opus[1m]", added_via: "api")
    AppSetting.editable.update!(default_runtime: "claude_code", default_model: "opus[1m]")

    delete api_v1_model_catalog_entry_path(entry), headers: @headers
    assert_response :unprocessable_entity
    assert_equal "Model in use", response.parsed_body["error"]

    AppSetting.editable.update!(default_model: nil)
    delete api_v1_model_catalog_entry_path(entry), headers: @headers
    assert_response :no_content
    refute ModelCatalogEntry.exists?(entry.id)
  end

  test "destroy of an unknown id is 404" do
    delete api_v1_model_catalog_entry_path(id: 0), headers: @headers
    assert_response :not_found
  end
end
