# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# A session gets its own repository owner's GitHub token and none of the others the
# worker holds (GithubTokens.session_env).
class CliSpawnEnvGithubTokenTest < ActiveSupport::TestCase
  class Host
    include CliSpawnEnv

    def initialize(logger:)
      @logger = logger
    end

    def apply!(env_vars, working_dir) = apply_github_token(env_vars, working_dir)
  end

  MAP = {
    "ZIMMER_GITHUB_TOKEN_ROUTING" => "1",
    "GH_TOKEN" => "github_pat_tadasant",
    "GH_TOKEN__PULSEMCP" => "github_pat_pulsemcp",
    "ZIMMER_GITHUB_DEFAULT_OWNER" => "tadasant"
  }.freeze

  setup do
    @original = MAP.keys.to_h { |key| [ key, ENV[key] ] }
    @logger = stub_everything("logger")
  end

  teardown do
    @original.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  test "a session on a pulsemcp clone gets the pulsemcp token, and the map is stripped" do
    MAP.each { |key, value| ENV[key] = value }
    GithubTokens.stubs(:owner_for_working_directory).with("/clone").returns("pulsemcp")

    env = Host.new(logger: @logger).apply!({}, "/clone")

    assert_equal "github_pat_pulsemcp", env["GH_TOKEN"]
    assert_equal "pulsemcp", env["ZIMMER_GITHUB_DEFAULT_OWNER"]
    assert env.key?("GH_TOKEN__PULSEMCP")
    assert_nil env["GH_TOKEN__PULSEMCP"], "nil unsets it in the child"
  end

  test "a value from the clone's .env wins" do
    MAP.each { |key, value| ENV[key] = value }
    GithubTokens.stubs(:owner_for_working_directory).returns("pulsemcp")

    env = Host.new(logger: @logger).apply!({ "GH_TOKEN" => "from-dotenv" }, "/clone")

    assert_equal "from-dotenv", env["GH_TOKEN"]
  end

  test "before routing is on, the session env is untouched" do
    ENV.delete("ZIMMER_GITHUB_TOKEN_ROUTING")
    GithubTokens.expects(:owner_for_working_directory).never

    assert_equal({ "A" => "b" }, Host.new(logger: @logger).apply!({ "A" => "b" }, "/clone"))
  end
end
