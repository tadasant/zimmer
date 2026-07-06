# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class SelfSessionInjectorTest < ActiveSupport::TestCase
  test "catalog_key resolves per environment with staging fallback for dev/test" do
    assert_equal "agent-orchestrator-prod-self-session",
      SelfSessionInjector.new(env: "production").catalog_key
    assert_equal "agent-orchestrator-staging-self-session",
      SelfSessionInjector.new(env: "staging").catalog_key
    assert_equal "agent-orchestrator-staging-self-session",
      SelfSessionInjector.new(env: "development").catalog_key
    assert_equal "agent-orchestrator-staging-self-session",
      SelfSessionInjector.new(env: "test").catalog_key
  end

  test "self_session_capable_present? matrix" do
    injector = SelfSessionInjector.new(env: "test")
    self_key = injector.catalog_key

    # TOOL_GROUPS blank (full surface) -> self-session capable
    assert injector.self_session_capable_present?(
      [ { name: "agent-orchestrator", tool_groups: nil } ]
    )

    # ALLOWED_AGENT_ROOTS does not hide tools; TOOL_GROUPS blank -> still capable
    assert injector.self_session_capable_present?(
      [ { name: "agent-orchestrator", tool_groups: "" } ]
    )

    # TOOL_GROUPS set -> NOT capable (self_session tools filtered out)
    refute injector.self_session_capable_present?(
      [ { name: "agent-orchestrator-prod-sessions", tool_groups: "sessions" } ]
    )

    # Non-AO server -> ignored
    refute injector.self_session_capable_present?(
      [ { name: "playwright-custom", tool_groups: nil } ]
    )

    # The self-session server itself -> ignored (excluded by name != self_key)
    refute injector.self_session_capable_present?(
      [ { name: self_key, tool_groups: nil } ]
    )
  end

  test "inject! yields catalog key and server when no capable AO server present" do
    injector = SelfSessionInjector.new(env: "staging")
    fake_server = Object.new
    yielded = nil

    ServersConfig.stub(:find, ->(key) { key == "agent-orchestrator-staging-self-session" ? fake_server : nil }) do
      result = injector.inject!(existing_ao_servers: [ { name: "playwright-custom", tool_groups: nil } ]) do |key, server|
        yielded = [ key, server ]
      end
      assert_equal "agent-orchestrator-staging-self-session", result
    end

    assert_equal [ "agent-orchestrator-staging-self-session", fake_server ], yielded
  end

  test "inject! skips and does not yield when a capable AO server is present" do
    injector = SelfSessionInjector.new(env: "staging")
    yielded = false

    result = injector.inject!(existing_ao_servers: [ { name: "agent-orchestrator", tool_groups: nil } ]) do |_key, _server|
      yielded = true
    end

    assert_nil result
    refute yielded
  end

  test "inject! returns nil and warns when catalog entry is missing" do
    injector = SelfSessionInjector.new(env: "staging")
    yielded = false

    ServersConfig.stub(:find, ->(_key) { nil }) do
      result = injector.inject!(existing_ao_servers: []) do |_key, _server|
        yielded = true
      end
      assert_nil result
    end

    refute yielded
  end

  test "ao_self_target resolves per environment" do
    ENV["AGENT_ORCHESTRATOR_LOCAL_API_KEY"] = "local-key"
    target = SelfSessionInjector.new(env: "development").ao_self_target
    assert_equal "http://localhost:3000", target[:base_url]
    assert_equal "local-key", target[:api_key]

    ENV["AGENT_ORCHESTRATOR_PROD_API_KEY"] = "prod-key"
    prod = SelfSessionInjector.new(env: "production").ao_self_target
    assert_equal "https://zimmer.example.com", prod[:base_url]
    assert_equal "prod-key", prod[:api_key]
  ensure
    ENV.delete("AGENT_ORCHESTRATOR_LOCAL_API_KEY")
    ENV.delete("AGENT_ORCHESTRATOR_PROD_API_KEY")
  end

  test "ao_self_target honors AGENT_ORCHESTRATOR_LOCAL_BASE_URL override" do
    ENV["AGENT_ORCHESTRATOR_LOCAL_BASE_URL"] = "http://localhost:9999"
    target = SelfSessionInjector.new(env: "development").ao_self_target
    assert_equal "http://localhost:9999", target[:base_url]
  ensure
    ENV.delete("AGENT_ORCHESTRATOR_LOCAL_BASE_URL")
  end
end
