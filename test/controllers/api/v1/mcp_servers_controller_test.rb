# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class Api::V1::McpServersControllerTest < ActionDispatch::IntegrationTest
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
    get api_v1_mcp_servers_path
    assert_response :unauthorized
    json = JSON.parse(response.body)
    assert_equal "Unauthorized", json["error"]
  end

  test "should return 401 with invalid API key" do
    get api_v1_mcp_servers_path, headers: { "X-API-Key" => "invalid_key" }
    assert_response :unauthorized
  end

  test "should accept valid API key" do
    get api_v1_mcp_servers_path, headers: @headers
    assert_response :success
  end

  # Response format tests
  test "should return JSON with correct content type" do
    get api_v1_mcp_servers_path, headers: @headers
    assert_response :success
    assert_equal "application/json; charset=utf-8", response.content_type
  end

  test "should return mcp_servers array" do
    get api_v1_mcp_servers_path, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    assert json.key?("mcp_servers")
    assert json["mcp_servers"].is_a?(Array)
  end

  test "should return server objects with only safe fields" do
    get api_v1_mcp_servers_path, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)

    # There should be at least one server in the test config
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

  test "should return servers from ServersConfig" do
    get api_v1_mcp_servers_path, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    server_names = json["mcp_servers"].map { |s| s["name"] }

    # The servers returned should match ServersConfig.names
    ServersConfig.names.each do |name|
      assert_includes server_names, name, "Expected server '#{name}' to be in response"
    end
  end

  test "server name should be string" do
    get api_v1_mcp_servers_path, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    json["mcp_servers"].each do |server|
      assert server["name"].is_a?(String), "Server name should be a string"
    end
  end

  test "server title should be string" do
    get api_v1_mcp_servers_path, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    json["mcp_servers"].each do |server|
      assert server["title"].is_a?(String), "Server title should be a string"
    end
  end

  # --- availability ----------------------------------------------------------
  #
  # An API client picking from this list has the same stake the session form's
  # picker does: a server whose required `${VAR}` does not resolve raises
  # MissingVariableError at prepare time and fails the whole session, not just
  # that server. The list said nothing about it until #538.

  test "every server carries an availability flag" do
    get api_v1_mcp_servers_path, headers: @headers
    assert_response :success

    JSON.parse(response.body)["mcp_servers"].each do |server|
      assert server.key?("unavailable"), "Server should have unavailable field"
      assert server.key?("unavailable_reason"), "Server should have unavailable_reason field"
      assert [ true, false ].include?(server["unavailable"]), "unavailable should be a boolean"
    end
  end

  test "a server that cannot start is flagged with a reason, and one that can is not" do
    with_mixed_availability_catalog do
      get api_v1_mcp_servers_path, headers: @headers
    end
    assert_response :success

    servers = JSON.parse(response.body)["mcp_servers"]

    healthy = option_for(servers, "context7")
    assert_equal false, healthy["unavailable"]
    assert_nil healthy["unavailable_reason"]

    unseeded = option_for(servers, "strad-secrets-staging-rw")
    assert_equal true, unseeded["unavailable"]
    assert_equal "STRAD_STAGING_API_KEY unresolved", unseeded["unavailable_reason"]

    declared = option_for(servers, "strad-secrets-oauth")
    assert_equal true, declared["unavailable"]
    assert_equal "The endpoint accepts only static bearer tokens and exposes no OAuth discovery.",
      declared["unavailable_reason"]
  end

  test "an unavailable server is still listed — it exists, and should not be re-registered" do
    with_mixed_availability_catalog do
      get api_v1_mcp_servers_path, headers: @headers
    end
    assert_response :success

    names = JSON.parse(response.body)["mcp_servers"].map { |s| s["name"] }
    assert_includes names, "strad-secrets-staging-rw"
    assert_equal 4, names.size
  end

  test "still exposes no sensitive field now that it serializes availability" do
    with_mixed_availability_catalog do
      get api_v1_mcp_servers_path, headers: @headers
    end
    assert_response :success

    JSON.parse(response.body)["mcp_servers"].each do |server|
      assert_equal %w[name title description unavailable unavailable_reason].sort, server.keys.sort
    end
  end
end
