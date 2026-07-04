# frozen_string_literal: true

require "test_helper"

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

  test "should return all three config sections" do
    get api_v1_configs_path, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    assert json.key?("mcp_servers"), "Response should include mcp_servers"
    assert json.key?("agent_roots"), "Response should include agent_roots"
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
end
