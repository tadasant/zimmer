# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class Api::V1::ConfigsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @valid_api_key = "test_api_key_12345"
    @headers = { "X-API-Key" => @valid_api_key }
    ENV["API_KEYS"] = @valid_api_key
  end

  teardown do
    ENV.delete("API_KEYS")
  end

  # Authentication tests
  test "should return 401 without API key" do
    get api_v1_configs_path
    assert_response :unauthorized
    json = JSON.parse(response.body)
    assert_equal "Unauthorized", json["error"]
  end

  test "should return 401 with invalid API key" do
    get api_v1_configs_path, headers: { "X-API-Key" => "invalid_key" }
    assert_response :unauthorized
  end

  test "should accept valid API key" do
    get api_v1_configs_path, headers: @headers
    assert_response :success
  end

  # Response format tests
  test "should return JSON with correct content type" do
    get api_v1_configs_path, headers: @headers
    assert_response :success
    assert_equal "application/json; charset=utf-8", response.content_type
  end

  test "should return all config sections" do
    get api_v1_configs_path, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    assert json.key?("mcp_servers"), "Response should include mcp_servers"
    assert json.key?("agent_roots"), "Response should include agent_roots"
    assert json.key?("runtime_models"), "Response should include runtime_models"
    assert json.key?("goals"), "Response should include goals"
  end

  # MCP Servers tests
  test "mcp_servers should be an array" do
    get api_v1_configs_path, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    assert json["mcp_servers"].is_a?(Array)
  end

  test "mcp_servers should contain only safe fields" do
    get api_v1_configs_path, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    assert json["mcp_servers"].any?, "Expected at least one MCP server in config"

    json["mcp_servers"].each do |server|
      # Should have only the safe fields
      assert server.key?("name"), "Server should have name field"
      assert server.key?("title"), "Server should have title field"
      assert server.key?("description"), "Server should have description field"

      # Should NOT have sensitive fields
      assert_not server.key?("env"), "Server should NOT expose env field"
      assert_not server.key?("args"), "Server should NOT expose args field"
      assert_not server.key?("command"), "Server should NOT expose command field"
      assert_not server.key?("url"), "Server should NOT expose url field"
      assert_not server.key?("headers"), "Server should NOT expose headers field"
      assert_not server.key?("type"), "Server should NOT expose type field"
    end
  end

  test "mcp_servers should match ServersConfig" do
    get api_v1_configs_path, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    server_names = json["mcp_servers"].map { |s| s["name"] }

    ServersConfig.names.each do |name|
      assert_includes server_names, name, "Expected server '#{name}' to be in response"
    end
  end

  # Agent Roots tests
  test "agent_roots should be an array" do
    get api_v1_configs_path, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    assert json["agent_roots"].is_a?(Array)
  end

  test "agent_roots should contain expected fields" do
    get api_v1_configs_path, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    assert json["agent_roots"].any?, "Expected at least one agent root in config"

    json["agent_roots"].each do |root|
      assert root.key?("name"), "Agent root should have name field"
      assert root.key?("display_name"), "Agent root should have display_name field"
      assert root.key?("description"), "Agent root should have description field"
      assert root.key?("url"), "Agent root should have url field"
      assert root.key?("default_branch"), "Agent root should have default_branch field"
      assert root.key?("subdirectory"), "Agent root should have subdirectory field"
      assert root.key?("custom"), "Agent root should have custom field"
      assert root.key?("default_goal"), "Agent root should have default_goal field"
      assert root.key?("default"), "Agent root should have default field"
      assert root.key?("default_mcp_servers"), "Agent root should have default_mcp_servers field"
    end
  end

  test "agent_roots should match AgentRootsConfig" do
    get api_v1_configs_path, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    root_names = json["agent_roots"].map { |r| r["name"] }

    AgentRootsConfig.names.each do |name|
      assert_includes root_names, name, "Expected agent root '#{name}' to be in response"
    end
  end

  # Runtime Models tests
  test "runtime_models should expose the model catalog grouped by runtime" do
    get api_v1_configs_path, headers: @headers
    assert_response :success

    runtime_models = JSON.parse(response.body)["runtime_models"]
    assert_equal "opus", runtime_models.dig("claude_code", "default")
    assert_equal "gpt-5.6-terra", runtime_models.dig("codex", "default")

    claude_ids = runtime_models.dig("claude_code", "models").map { |model| model["id"] }
    codex_ids = runtime_models.dig("codex", "models").map { |model| model["id"] }

    assert_equal %w[opus sonnet haiku fable], claude_ids
    assert_includes codex_ids, "gpt-5.6-sol"
    assert_includes codex_ids, "gpt-5.6-terra"
    assert_includes codex_ids, "gpt-5.6-luna"
    refute_includes claude_ids, "gpt-5.6-sol"
    refute_includes codex_ids, "fable"
  end

  test "runtime_models entries expose labels and auth/default flags" do
    get api_v1_configs_path, headers: @headers
    assert_response :success

    runtime_models = JSON.parse(response.body)["runtime_models"]
    sol = runtime_models.dig("codex", "models").find { |model| model["id"] == "gpt-5.6-sol" }
    terra = runtime_models.dig("codex", "models").find { |model| model["id"] == "gpt-5.6-terra" }
    fable = runtime_models.dig("claude_code", "models").find { |model| model["id"] == "fable" }

    assert_equal "gpt-5.6-sol (ChatGPT auth)", sol["label"]
    assert_equal false, sol["default"]
    assert_equal true, sol["requires_oauth"]
    assert_equal "gpt-5.6-terra (default, ChatGPT auth)", terra["label"]
    assert_equal true, terra["default"]
    assert_equal true, terra["requires_oauth"]
    assert_equal "fable", fable["label"]
    assert_equal false, fable["default"]
    assert_equal false, fable["requires_oauth"]
  end

  # Goals tests
  test "goals should be an array" do
    get api_v1_configs_path, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    assert json["goals"].is_a?(Array)
  end

  test "goals should contain expected fields" do
    get api_v1_configs_path, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    assert json["goals"].any?, "Expected at least one goal in config"

    json["goals"].each do |condition|
      assert condition.key?("id"), "Goal should have id field"
      assert condition.key?("name"), "Goal should have name field"
      assert condition.key?("description"), "Goal should have description field"
    end
  end

  test "goals should match GoalsConfig" do
    get api_v1_configs_path, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    condition_ids = json["goals"].map { |c| c["id"] }

    GoalsConfig.ids.each do |id|
      assert_includes condition_ids, id, "Expected goal '#{id}' to be in response"
    end
  end

  # Field type tests
  test "all string fields should be strings" do
    get api_v1_configs_path, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)

    json["mcp_servers"].each do |server|
      assert server["name"].is_a?(String), "Server name should be a string"
      assert server["title"].is_a?(String), "Server title should be a string"
    end

    json["agent_roots"].each do |root|
      assert root["name"].is_a?(String), "Agent root name should be a string"
      assert root["display_name"].is_a?(String), "Agent root display_name should be a string"
      assert root["default_branch"].is_a?(String), "Agent root default_branch should be a string"
    end

    json["goals"].each do |condition|
      assert condition["id"].is_a?(String), "Goal id should be a string"
      assert condition["name"].is_a?(String), "Goal name should be a string"
    end
  end

  test "boolean fields should be booleans" do
    get api_v1_configs_path, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)

    json["agent_roots"].each do |root|
      assert [ true, false ].include?(root["custom"]), "Agent root custom should be a boolean"
      assert [ true, false ].include?(root["default"]), "Agent root default should be a boolean"
    end
  end

  test "array fields should be arrays" do
    get api_v1_configs_path, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)

    json["agent_roots"].each do |root|
      assert root["default_mcp_servers"].is_a?(Array), "Agent root default_mcp_servers should be an array"
    end
  end

  # --- MCP server availability -----------------------------------------------
  #
  # This endpoint is how an API client discovers what it may attach to a
  # session. Until #538 it described every catalog server identically, including
  # ones Zimmer already knew could not start — and attaching one of those raises
  # SecretsInterpolator::MissingVariableError at prepare time, failing the whole
  # session rather than just that server.

  test "every mcp_server carries an availability flag" do
    get api_v1_configs_path, headers: @headers
    assert_response :success

    JSON.parse(response.body)["mcp_servers"].each do |server|
      assert server.key?("unavailable"), "Server should have unavailable field"
      assert server.key?("unavailable_reason"), "Server should have unavailable_reason field"
      assert [ true, false ].include?(server["unavailable"]), "unavailable should be a boolean"
    end
  end

  test "flags a server whose required variable does not resolve, and names the variable" do
    with_mixed_availability_catalog do
      get api_v1_configs_path, headers: @headers
    end
    assert_response :success

    servers = JSON.parse(response.body)["mcp_servers"]

    unseeded = option_for(servers, "strad-secrets-staging-rw")
    assert_equal true, unseeded["unavailable"]
    assert_equal "STRAD_STAGING_API_KEY unresolved", unseeded["unavailable_reason"]
  end

  test "flags a server the catalog declares unavailable with the catalog's own reason" do
    with_mixed_availability_catalog do
      get api_v1_configs_path, headers: @headers
    end
    assert_response :success

    declared = option_for(JSON.parse(response.body)["mcp_servers"], "strad-secrets-oauth")
    assert_equal true, declared["unavailable"]
    assert_equal "The endpoint accepts only static bearer tokens and exposes no OAuth discovery.",
      declared["unavailable_reason"]
  end

  test "leaves a startable server unflagged and its reason null" do
    with_mixed_availability_catalog do
      get api_v1_configs_path, headers: @headers
    end
    assert_response :success

    healthy = option_for(JSON.parse(response.body)["mcp_servers"], "context7")
    assert_equal false, healthy["unavailable"]
    assert_nil healthy["unavailable_reason"]
  end

  # The response describes the catalog; it does not filter it. Dropping an
  # unavailable server would tell a client it does not exist, and the useful
  # instruction is the opposite one — it exists, do not register a replacement.
  test "does not drop unavailable servers from the list" do
    with_mixed_availability_catalog do
      get api_v1_configs_path, headers: @headers
    end
    assert_response :success

    names = JSON.parse(response.body)["mcp_servers"].map { |s| s["name"] }
    assert_equal %w[context7 zimmer-self-session strad-secrets-staging-rw strad-secrets-oauth], names
  end

  # "The secret store did not answer" is not "this secret is not set". Flagging
  # on an indeterminate answer would empty a client's options during a store
  # blip, so ConnectorStatusProbe deliberately reports those as available.
  test "does not flag a server whose secret store could not be reached" do
    outage = SecretsInterpolator::Resolution.new(
      state: :unavailable, error: StandardError.new("Parameter Store timed out")
    )
    with_mixed_availability_catalog(resolution: outage) do
      get api_v1_configs_path, headers: @headers
    end
    assert_response :success

    unreachable = option_for(JSON.parse(response.body)["mcp_servers"], "strad-secrets-staging-rw")
    assert_equal false, unreachable["unavailable"]
  end
end
