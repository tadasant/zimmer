# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# Issue #618's mechanism, at the one seam that decides what a `claude` process is
# actually handed. The session gets a CLAUDE_CODE_OAUTH_TOKEN and its own
# CLAUDE_CONFIG_DIR, so it holds an access token and no refresh token — it cannot
# rotate the subscription chain, which is what makes the DB the sole owner rather
# than merely the preferred one.
#
# This is unconditional now. There is no setting, and — the part these tests are
# most concerned with — no fallback: `~/.claude/.credentials.json` is a file
# nothing writes, so a spawn that cannot be given a token has to fail rather than
# hand the child a fossil.
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

  test "the session gets its own config dir and the current account's access token" do
    env = Host.new(session_id: 886, logger: @logger).apply!

    assert_equal File.join(@config_base, "886"), env["CLAUDE_CONFIG_DIR"]
    assert_equal @account.claude_access_token, env["CLAUDE_CODE_OAUTH_TOKEN"]
    assert Dir.exist?(env["CLAUDE_CONFIG_DIR"]), "the config dir must exist by the time the process starts"
  end

  test "records the token generation actually handed to the child" do
    session = Session.create!(
      prompt: "Scoped mode", agent_runtime: "claude_code", status: :running,
      git_root: "https://github.com/test/repo.git", branch: "main", session_id: SecureRandom.uuid
    )

    Host.new(session_id: session.id, logger: @logger).apply!

    metadata = session.reload.metadata
    assert_equal AuthRecoveryCoordinator.credential_fingerprint(@account),
      metadata[AuthRecoveryCoordinator::CREDENTIAL_FINGERPRINT_KEY]
    assert_equal @account.email, metadata[AuthRecoveryCoordinator::IDENTITY_KEY]
  end

  # The whole point. A refresh token in the child's environment would let the CLI
  # rotate the chain, which is the thing that destroyed a credential on
  # 2026-08-22.
  test "the session is never handed a refresh token" do
    refresh = @account.oauth_config.dig("credentials_json", "claudeAiOauth", "refreshToken")
    assert refresh.present?, "fixture must carry a refresh token for this test to bite"

    env = Host.new(session_id: 886, logger: @logger).apply!

    assert_not_includes env.values.compact, refresh
  end

  test "each session gets a different config dir" do
    first = Host.new(session_id: 1, logger: @logger).apply!
    second = Host.new(session_id: 2, logger: @logger).apply!

    assert_not_equal first["CLAUDE_CONFIG_DIR"], second["CLAUDE_CONFIG_DIR"]
  end

  # Stability, not freshness, is what `--resume` needs: Claude Code keeps its
  # conversation state under CLAUDE_CONFIG_DIR, so the same Zimmer session must
  # resolve to the same directory on every spawn.
  test "the same session resolves to the same config dir across spawns" do
    first = Host.new(session_id: 886, logger: @logger).apply!
    second = Host.new(session_id: 886, logger: @logger).apply!

    assert_equal first["CLAUDE_CONFIG_DIR"], second["CLAUDE_CONFIG_DIR"]
  end

  # ── the no-usable-account path ────────────────────────────────────────
  #
  # These four used to assert a fallback to the shared credentials file. There is
  # nothing to fall back TO now, so each has to fail the spawn instead. A session
  # that cannot authenticate answers every turn with "Not logged in · Please run
  # /login"; failing here makes that visible as a spawn failure with a cause,
  # rather than as a session that runs and cannot think.

  test "raises when no account is current" do
    ClaudeAccount.update_all(is_current: false)

    error = assert_raises(ClaudeSpawnEnv::MissingCredentialsError) do
      Host.new(session_id: 886, logger: @logger).apply!
    end
    assert_match(/authenticate one from \/inference/, error.message)
  end

  test "raises when the current account holds no access token" do
    @account.update!(oauth_config: {})

    error = assert_raises(ClaudeSpawnEnv::MissingCredentialsError) do
      Host.new(session_id: 886, logger: @logger).apply!
    end
    # The message names the account that came up empty, so the operator knows
    # which one to re-authenticate.
    assert_match(/#{@account.email}/, error.message)
  end

  test "raises when there is no session id to key a config dir on" do
    assert_raises(ClaudeSpawnEnv::MissingCredentialsError) do
      Host.new(session_id: nil, logger: @logger).apply!
    end
  end

  test "a DB failure fails the spawn rather than silently producing a credential-less child" do
    ClaudeAccount.stubs(:current_account).raises(ActiveRecord::ConnectionNotEstablished, "database unavailable")

    assert_raises(ActiveRecord::ConnectionNotEstablished) do
      Host.new(session_id: 886, logger: @logger).apply!
    end
  end

  # Half-applied is the one outcome worse than either: a CLAUDE_CONFIG_DIR with
  # no token points the session at an empty credential store.
  test "a failure part-way through leaves neither variable behind" do
    ClaudeSessionConfigDirectory.stubs(:ensure_for).raises(Errno::EACCES)
    env = {}

    assert_raises(Errno::EACCES) { Host.new(session_id: 886, logger: @logger).apply!(env) }

    assert_not env.key?("CLAUDE_CONFIG_DIR")
    assert_not env.key?("CLAUDE_CODE_OAUTH_TOKEN")
  end

  # Recording the spawn identity is observability, not a prerequisite for the
  # child. It is rescued so a metadata write that fails cannot take a spawn with
  # it — but the token still has to reach the env.
  test "a failed identity record does not stop the credentials reaching the child" do
    AuthRecoveryCoordinator.stubs(:record_spawn_credentials!).raises(StandardError, "metadata write failed")

    env = Host.new(session_id: 886, logger: @logger).apply!

    assert_equal @account.claude_access_token, env["CLAUDE_CODE_OAUTH_TOKEN"]
  end
end
