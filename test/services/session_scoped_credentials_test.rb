# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# The credential-ownership rearchitecture from issue #618, across the pieces that
# have to agree for it to mean anything: nothing writes a subscription token to
# the filesystem at all, MCP tokens are read and written per session, re-auth is
# one DB write, and the health surface describes the store sessions actually use.
#
# There is no setting and no off path any more. `~/.claude/.credentials.json` is
# not a rollback, it is a file nothing reads — so these tests assert the
# behaviour unconditionally, and several of them assert that a home directory
# left entirely untouched is the outcome.
class SessionScopedCredentialsTest < ActiveSupport::TestCase
  setup do
    @config_base = Dir.mktmpdir("claude-config-base")
    @claude_home = Dir.mktmpdir("claude-home")
    ENV["CLAUDE_SESSION_CONFIG_DIR"] = @config_base
    # Nothing under test should write here. Pointing the transcript root at a
    # temp dir keeps the `projects/` symlink out of the real ~/.claude, and
    # makes "the home directory is untouched" an assertion rather than a hope.
    ClaudeTranscriptSource.stubs(:projects_root).returns(File.join(@claude_home, "projects"))
  end

  teardown do
    ENV.delete("CLAUDE_SESSION_CONFIG_DIR")
    FileUtils.rm_rf(@config_base)
    FileUtils.rm_rf(@claude_home)
  end

  # ── the filesystem is never written ───────────────────────────────────

  test "AccountRotationService has no filesystem write path left" do
    refute AccountRotationService.instance_methods(false).include?(:write_config!),
      "write_config! was the one method that could put a subscription refresh token on disk"
    refute AccountRotationService.private_instance_methods(false).include?(:sync_current_tokens)
    refute AccountRotationService.private_instance_methods(false).include?(:capture_outgoing_filesystem_tokens)
    refute AccountRotationService.private_instance_methods(false).include?(:bootstrap_owner_marker)
  end

  test "ClaudeAccount has no shared-credentials machinery left" do
    %i[
      sync_tokens_from_filesystem! write_credentials_to_filesystem!
      backfill_identity_from_filesystem!
    ].each do |gone|
      refute ClaudeAccount.new.respond_to?(gone, true), "ClaudeAccount##{gone} should be deleted"
    end

    %i[credentials_owner_email write_credentials_owner_marker! filesystem_identity_email].each do |gone|
      refute ClaudeAccount.respond_to?(gone), "ClaudeAccount.#{gone} should be deleted"
    end

    refute ClaudeAuthProvider.respond_to?(:credentials_owner_path),
      "the .ao-credentials-owner.json marker has no referent without a shared file"
  end

  test "activate! is a DB write and a snapshot, with no filesystem step" do
    secondary = claude_accounts(:secondary)
    # Unreachable, so the probe is a no-op rather than a verdict: this test is
    # about activate! touching no filesystem, not about credential state.
    QuotaCheckService.stubs(:check_with_token).returns(
      QuotaCheckService::Result.new(success: false, unreachable: true, error_message: "skip")
    )

    AccountRotationService.new.activate!(secondary, snapshot_trigger: "manual_switch")

    assert secondary.reload.is_current?
    assert_empty Dir.children(@claude_home)
  end

  test "ensure_active_account! keeps a healthy current account without touching the filesystem" do
    primary = claude_accounts(:primary)
    primary.update!(is_current: true, status: :active)

    assert_equal primary, AccountRotationService.new.ensure_active_account!
    assert_empty Dir.children(@claude_home)
  end

  test "ensure_active_account! drops a current account whose stored token Anthropic refused" do
    primary = claude_accounts(:primary)
    primary.update!(is_current: true, status: :active)
    primary.record_credential_probe!(
      QuotaCheckService::Result.new(success: false, unreachable: false, status_code: 401,
        error_message: "No rate-limit headers in response (HTTP 401)."),
      probed_token: primary.claude_access_token
    )
    # The live re-probe agrees with the recorded verdict: this token is dead.
    QuotaCheckService.stubs(:check_with_token).returns(
      QuotaCheckService::Result.new(success: true, utilization_5h: 0.1, utilization_7d: 0.1,
        status_5h: "allowed", status_7d: "allowed")
    )
    QuotaCheckService.stubs(:check_with_token)
      .with(primary.oauth_config.dig("credentials_json", "claudeAiOauth", "accessToken"))
      .returns(QuotaCheckService::Result.new(success: false, unreachable: false, status_code: 401,
        error_message: "No rate-limit headers in response (HTTP 401)."))
    ClaudeAccount.any_instance.stubs(:refresh_token!).returns(false)

    promoted = AccountRotationService.new.ensure_active_account!

    assert_not_equal primary, promoted,
      "the stored token IS what the session is handed, so a recorded refusal is about it"
    assert promoted.present?
  end

  test "ensure_active_account! answers nil when the pool holds nothing usable" do
    ClaudeAccount.for_runtime(ClaudeAuthProvider::RUNTIME).update_all(oauth_config: {}, is_current: false)

    assert_nil AccountRotationService.new.ensure_active_account!
  end

  # ── MCP OAuth moves with the session ──────────────────────────────────

  test "the MCP credential writer targets the session's own config dir" do
    session = sessions(:active_session)

    writer = ClaudeMcpCredentialWriter.for_session(session)

    assert_equal ClaudeSessionConfigDirectory.credentials_path_for(session.id), writer.credentials_path
  end

  test "there is no host-global MCP credential writer to build" do
    assert_raises(ArgumentError) { ClaudeMcpCredentialWriter.new }
    assert_nil ClaudeMcpCredentialWriter.for_session(Object.new),
      "a caller with no session id has no per-session store to write into"
    assert ClaudeMcpCredentialWriter.session_scoped_store?
  end

  # A rotated MCP token lands in the session's file and is read back from there.
  # This is the smaller instance of the same sync problem, and it is what makes
  # the remaining credentials file harmless: it holds mcpOAuth and nothing else.
  test "a token written for one session is invisible to another session's store" do
    one = ClaudeMcpCredentialWriter.for_session(sessions(:active_session))
    one.stubs(:macos?).returns(false)
    one.write!(working_directory: @config_base, credentials: [ resolved_credential ])

    two = ClaudeMcpCredentialWriter.new(
      credentials_path: ClaudeSessionConfigDirectory.credentials_path_for(999_999)
    )
    two.stubs(:macos?).returns(false)

    assert_equal "access-token-xyz", one.read_runtime_credentials["notion|abc123"].access_token
    assert_empty two.read_runtime_credentials
  end

  test "the session's credentials file never gains a claudeAiOauth block from Zimmer" do
    session = sessions(:active_session)

    writer = ClaudeMcpCredentialWriter.for_session(session)
    writer.stubs(:macos?).returns(false)
    writer.write!(working_directory: @config_base, credentials: [ resolved_credential ])

    data = JSON.parse(File.read(writer.credentials_path))
    assert_equal [ "mcpOAuth" ], data.keys
  end

  test "the cron MCP sweep skips Claude Code, whose store is per session" do
    reconcilers = RefreshMcpOauthTokensJob.new.send(:runtime_reconcilers)

    refute_includes reconcilers.map { |writer, _| writer.class }, ClaudeMcpCredentialWriter,
      "there is no single Claude store for a session-less sweep to read"
  end

  # ── the refresh path never reconciles against a file ──────────────────

  # The regression an earlier fresh-eyes review caught. #lost_refresh_race? used
  # to re-sync from the shared file on every rejected refresh; pulling that file
  # back would overwrite the DB's live pair with a superseded one and then report
  # the account healthy — the 2026-08-22 shape, through the one path this work
  # was meant to close.
  test "a rejected refresh consults no filesystem at all" do
    account = claude_accounts(:primary)
    account.update!(is_current: true)

    account.send(:lost_refresh_race?, "some-presented-value")

    assert_empty Dir.children(@claude_home)
  end

  test "a refresh presents the DB token captured by re-auth" do
    account = claude_accounts(:secondary)

    capture_login!(account)
    sent_refresh_token = stub_successful_refresh!

    assert account.refresh_token!
    assert_equal "fresh-refresh", sent_refresh_token.call,
      "the row is the only store; nothing may overwrite a completed login"
  end

  test "a successful refresh of the current account writes nothing to disk" do
    account = claude_accounts(:primary)
    account.update!(is_current: true)
    stub_successful_refresh!

    assert account.refresh_token!
    assert_equal "rotated-refresh", account.reload.claude_refresh_token
    assert_empty Dir.children(@claude_home)
  end

  # ── the sweep reads no filesystem back ────────────────────────────────

  test "Claude implements neither filesystem dispatcher hook" do
    provider = ClaudeAuthProvider.new

    assert_nil provider.sync_current_account_tokens!
    assert_nil provider.reconcile_filesystem_identity!
    refute ClaudeAuthProvider.instance_methods(false).include?(:sync_current_account_tokens!)
  end

  # ── re-auth is one write ──────────────────────────────────────────────

  test "capturing a login for the current account writes only the DB" do
    account = claude_accounts(:primary)
    account.update!(is_current: true)

    capture_login!(account)

    assert_equal "fresh-access", account.reload.claude_access_token
    assert_empty Dir.children(@claude_home)
  end

  # ── the health surface describes the store in use ─────────────────────

  test "health reports the DB as the credential store, naming the current account" do
    claude_accounts(:primary).update!(is_current: true, status: :active)

    status = ClaudeCredentialHealth.status

    assert_equal :ok, status.state
    assert_equal "tadas@tadasant.com", status.owner_email
    assert_match(/authenticate from the database/, status.detail)
  end

  test "health reports corrupt when the current account's stored tokens are unusable" do
    claude_accounts(:primary).update!(is_current: true, oauth_config: { "credentials_json" => {} })

    status = ClaudeCredentialHealth.status

    assert_equal :corrupt, status.state
    assert_match(/Re-authenticate/, status.detail)
  end

  test "health reports absent when nothing is current yet" do
    ClaudeAccount.update_all(is_current: false)

    assert_equal :absent, ClaudeCredentialHealth.status.state
  end

  test "health offers no self-heal, because a DB row is the bottom of the stack" do
    refute ClaudeCredentialHealth.respond_to?(:self_heal!),
      "a corrupt file could be rewritten from the DB; a corrupt row needs a human"
  end

  # ── the setting is retired ────────────────────────────────────────────

  test "the experimental toggle is gone from the registry and the model" do
    assert_nil ExperimentalSettingsRegistry.find("session_scoped_credentials")
    refute_includes ExperimentalSettingsRegistry.keys, "session_scoped_credentials"
    refute AppSetting.respond_to?(:session_scoped_credentials_enabled?)
    refute_includes AppSetting.column_names, "session_scoped_credentials_enabled",
      "phase 1 of the two-phase drop hides the column from the model"
  end

  private

  def resolved_credential
    ResolvedMcpCredential.new(
      credential_key: "notion|abc123",
      server_name: "notion",
      server_url: "https://mcp.notion.com/v1/mcp",
      client_id: "client-123",
      access_token: "access-token-xyz",
      refresh_token: "refresh-token-123",
      expires_at: 1.hour.from_now,
      scope: nil,
      headers: {}
    )
  end

  def stub_successful_refresh!
    sent_refresh_token = nil
    response = Net::HTTPSuccess.new("1.1", "200", "OK")
    response.stubs(:code).returns("200")
    response.stubs(:body).returns({
      access_token: "rotated-access",
      refresh_token: "rotated-refresh",
      expires_in: 3600
    }.to_json)
    Net::HTTP.any_instance.stubs(:request).with do |request|
      sent_refresh_token = URI.decode_www_form(request.body).to_h["refresh_token"]
      true
    end.returns(response)

    -> { sent_refresh_token }
  end

  # Drive ClaudeLoginDriver#capture! against a scratch dir holding a complete,
  # Anthropic-honoured token pair — the state a finished interactive login leaves.
  def capture_login!(account)
    QuotaCheckService.stubs(:check_with_token).returns(
      QuotaCheckService::Result.new(success: true, utilization_5h: 0.1, utilization_7d: 0.1)
    )

    Dir.mktmpdir("claude-login-scratch") do |scratch|
      File.write(File.join(scratch, ".credentials.json"), JSON.generate(
        "claudeAiOauth" => {
          "accessToken" => "fresh-access",
          "refreshToken" => "fresh-refresh",
          "expiresAt" => ((Time.current + 8.hours).to_f * 1000).to_i
        }
      ))
      File.write(File.join(scratch, ".claude.json"), JSON.generate(
        "oauthAccount" => { "emailAddress" => account.email }
      ))

      ClaudeLoginDriver.new.capture!(scratch, account)
    end
  end
end
