# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# Issue #618's mechanism, at the one seam that decides what a `claude` process is
# actually handed. If the session gets a CLAUDE_CODE_OAUTH_TOKEN and its own
# CLAUDE_CONFIG_DIR, it holds an access token and no refresh token — so it
# cannot rotate the subscription chain, which is what makes the DB the sole
# owner rather than merely the preferred one.
class ClaudeSpawnEnvSessionCredentialsTest < ActiveSupport::TestCase
  # Minimal host for the shared module, matching what the real adapters expose.
  class Host
    include ClaudeSpawnEnv

    def initialize(session_id:, logger:)
      @zimmer_session_id = session_id
      @logger = logger
    end

    def apply!(env_vars = {})
      apply_session_scoped_credentials(env_vars)
    end
  end

  setup do
    @logger = stub_everything("logger")
    @config_base = Dir.mktmpdir("claude-config-base")
    ENV["CLAUDE_SESSION_CONFIG_DIR"] = @config_base
    @account = claude_accounts(:primary)
    @account.update!(is_current: true)
  end

  teardown do
    ENV.delete("CLAUDE_SESSION_CONFIG_DIR")
    FileUtils.rm_rf(@config_base)
  end

  test "with the setting off, neither variable is set and the session reads the shared file" do
    AppSetting.stubs(:session_scoped_credentials_enabled?).returns(false)

    env = Host.new(session_id: 886, logger: @logger).apply!

    assert_not env.key?("CLAUDE_CONFIG_DIR")
    assert_not env.key?("CLAUDE_CODE_OAUTH_TOKEN")
  end

  test "with the setting on, the session gets its own config dir and the current account's access token" do
    AppSetting.stubs(:session_scoped_credentials_enabled?).returns(true)

    env = Host.new(session_id: 886, logger: @logger).apply!

    assert_equal File.join(@config_base, "886"), env["CLAUDE_CONFIG_DIR"]
    assert_equal @account.claude_access_token, env["CLAUDE_CODE_OAUTH_TOKEN"]
    assert Dir.exist?(env["CLAUDE_CONFIG_DIR"]), "the config dir must exist by the time the process starts"
  end

  # The whole point. A refresh token in the child's environment would let the CLI
  # rotate the chain, which is the thing that destroyed a credential on
  # 2026-08-22.
  test "the session is never handed a refresh token" do
    AppSetting.stubs(:session_scoped_credentials_enabled?).returns(true)
    refresh = @account.oauth_config.dig("credentials_json", "claudeAiOauth", "refreshToken")
    assert refresh.present?, "fixture must carry a refresh token for this test to bite"

    env = Host.new(session_id: 886, logger: @logger).apply!

    assert_not_includes env.values.compact, refresh
  end

  test "each session gets a different config dir" do
    AppSetting.stubs(:session_scoped_credentials_enabled?).returns(true)

    first = Host.new(session_id: 1, logger: @logger).apply!
    second = Host.new(session_id: 2, logger: @logger).apply!

    assert_not_equal first["CLAUDE_CONFIG_DIR"], second["CLAUDE_CONFIG_DIR"]
  end

  # Stability, not freshness, is what `--resume` needs: Claude Code keeps its
  # conversation state under CLAUDE_CONFIG_DIR, so the same Zimmer session must
  # resolve to the same directory on every spawn.
  test "the same session resolves to the same config dir across spawns" do
    AppSetting.stubs(:session_scoped_credentials_enabled?).returns(true)

    first = Host.new(session_id: 886, logger: @logger).apply!
    second = Host.new(session_id: 886, logger: @logger).apply!

    assert_equal first["CLAUDE_CONFIG_DIR"], second["CLAUDE_CONFIG_DIR"]
  end

  test "falls back to the shared file when no account is current" do
    AppSetting.stubs(:session_scoped_credentials_enabled?).returns(true)
    ClaudeAccount.update_all(is_current: false)

    env = Host.new(session_id: 886, logger: @logger).apply!

    assert_not env.key?("CLAUDE_CONFIG_DIR")
    assert_not env.key?("CLAUDE_CODE_OAUTH_TOKEN")
  end

  test "falls back to the shared file when the current account holds no access token" do
    AppSetting.stubs(:session_scoped_credentials_enabled?).returns(true)
    @account.update!(oauth_config: {})

    env = Host.new(session_id: 886, logger: @logger).apply!

    assert_not env.key?("CLAUDE_CONFIG_DIR")
    assert_not env.key?("CLAUDE_CODE_OAUTH_TOKEN")
  end

  test "a session-less spawn is left alone" do
    AppSetting.stubs(:session_scoped_credentials_enabled?).returns(true)

    env = Host.new(session_id: nil, logger: @logger).apply!

    assert_not env.key?("CLAUDE_CONFIG_DIR")
    assert_not env.key?("CLAUDE_CODE_OAUTH_TOKEN")
  end

  # Half-applied is the one outcome worse than either: a CLAUDE_CONFIG_DIR with
  # no token points the session at an empty credential store.
  test "a failure part-way through leaves neither variable behind" do
    AppSetting.stubs(:session_scoped_credentials_enabled?).returns(true)
    ClaudeSessionConfigDirectory.stubs(:ensure_for).raises(Errno::EACCES)

    env = Host.new(session_id: 886, logger: @logger).apply!

    assert_not env.key?("CLAUDE_CONFIG_DIR")
    assert_not env.key?("CLAUDE_CODE_OAUTH_TOKEN")
  end
end
