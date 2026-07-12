# frozen_string_literal: true

require "test_helper"

class SelfSessionInjectorTest < ActiveSupport::TestCase
  test "endpoint_url points at this instance's native MCP endpoint, with scoping" do
    ENV["ZIMMER_LOCAL_BASE_URL"] = "http://localhost:4000"
    injector = SelfSessionInjector.new(env: "development")

    assert_equal "http://localhost:4000/mcp", injector.endpoint_url
    assert_equal "http://localhost:4000/mcp?tool_groups=self_session",
      injector.endpoint_url(tool_groups: "self_session")
    assert_equal "http://localhost:4000/mcp?allowed_agent_roots=zimmer%2Cdocs",
      injector.endpoint_url(allowed_agent_roots: "zimmer,docs")
  ensure
    ENV.delete("ZIMMER_LOCAL_BASE_URL")
  end

  test "headers carry the instance's API key" do
    ENV["ZIMMER_LOCAL_API_KEY"] = "local-key"
    assert_equal({ "X-API-Key" => "local-key" }, SelfSessionInjector.new(env: "development").headers)
  ensure
    ENV.delete("ZIMMER_LOCAL_API_KEY")
  end

  test "self_session_capable_present? matrix" do
    injector = SelfSessionInjector.new(env: "test")

    # Full-surface Zimmer server (no tool_groups) -> covers self_session
    assert injector.self_session_capable_present?(
      [ { name: "zimmer", url: "http://localhost:3000/mcp?allowed_agent_roots=docs" } ]
    )

    # Scoped to a group set that includes self_session -> covers it
    assert injector.self_session_capable_present?(
      [ { name: "zimmer-full", url: "http://localhost:3000/mcp?tool_groups=sessions,self_session" } ]
    )

    # Scoped to other groups -> does NOT cover self_session
    refute injector.self_session_capable_present?(
      [ { name: "zimmer-sessions", url: "http://localhost:3000/mcp?tool_groups=sessions" } ]
    )

    # A third-party server that happens to be served at /mcp -> ignored
    refute injector.self_session_capable_present?(
      [ { name: "figma", url: "https://mcp.figma.com/mcp" } ]
    )

    # The self-session server itself -> ignored, so re-running injection is idempotent
    refute injector.self_session_capable_present?(
      [ { name: "zimmer-self-session", url: "http://localhost:3000/mcp?tool_groups=self_session" } ]
    )

    # A zimmer-named entry with no URL is not one of our HTTP endpoints. Treating it
    # as capable would silently strip the session's self-archiving and wake-up tools.
    refute injector.self_session_capable_present?(
      [ { name: "zimmer-legacy", url: nil } ]
    )
  end

  test "inject! yields the native self-session entry when nothing covers the surface" do
    ENV["ZIMMER_LOCAL_API_KEY"] = "local-key"
    injector = SelfSessionInjector.new(env: "development")
    yielded = nil

    result = injector.inject!(existing_servers: [ { name: "playwright-custom", url: nil } ]) do |name, url, headers|
      yielded = [ name, url, headers ]
    end

    assert_equal "zimmer-self-session", result
    assert_equal "zimmer-self-session", yielded[0]
    assert_equal "http://localhost:3000/mcp?tool_groups=self_session", yielded[1]
    assert_equal({ "X-API-Key" => "local-key" }, yielded[2])
  ensure
    ENV.delete("ZIMMER_LOCAL_API_KEY")
  end

  test "inject! skips and does not yield when a full-surface Zimmer server is present" do
    injector = SelfSessionInjector.new(env: "staging")
    yielded = false

    result = injector.inject!(existing_servers: [ { name: "zimmer", url: "https://staging.zimmer.example.com/mcp" } ]) do
      yielded = true
    end

    assert_nil result
    refute yielded
  end

  test "self_target resolves per environment" do
    prod_base_url = ENV.delete("ZIMMER_PROD_BASE_URL")
    ENV["ZIMMER_LOCAL_API_KEY"] = "local-key"
    target = SelfSessionInjector.new(env: "development").self_target
    assert_equal "http://localhost:3000", target[:base_url]
    assert_equal "local-key", target[:api_key]

    ENV["ZIMMER_PROD_API_KEY"] = "prod-key"
    prod = SelfSessionInjector.new(env: "production").self_target
    assert_equal "https://zimmer.example.com", prod[:base_url]
    assert_equal "prod-key", prod[:api_key]
  ensure
    ENV.delete("ZIMMER_LOCAL_API_KEY")
    ENV.delete("ZIMMER_PROD_API_KEY")
    ENV["ZIMMER_PROD_BASE_URL"] = prod_base_url if prod_base_url
  end

  test "self_target honors ZIMMER_LOCAL_BASE_URL override" do
    ENV["ZIMMER_LOCAL_BASE_URL"] = "http://localhost:9999"
    target = SelfSessionInjector.new(env: "development").self_target
    assert_equal "http://localhost:9999", target[:base_url]
  ensure
    ENV.delete("ZIMMER_LOCAL_BASE_URL")
  end
end
