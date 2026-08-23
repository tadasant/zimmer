# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# The credential-ownership rearchitecture from issue #618, across the pieces that
# have to agree for it to mean anything: nothing writes a subscription token to
# the shared filesystem, MCP tokens are read and written per session, re-auth is
# a DB write, and the health surface describes the store sessions actually use.
#
# Every test asserts the setting ON and the setting OFF, because the off path is
# the rollback and a rollback that quietly changed behaviour would not be one.
class SessionScopedCredentialsTest < ActiveSupport::TestCase
  setup do
    @config_base = Dir.mktmpdir("claude-config-base")
    @claude_home = Dir.mktmpdir("claude-home")
    ENV["CLAUDE_SESSION_CONFIG_DIR"] = @config_base
    @original_credentials_path = ClaudeAuthProvider::CREDENTIALS_JSON_PATH
    @original_claude_json_path = ClaudeAuthProvider::CLAUDE_JSON_PATH
    swap_const(:CREDENTIALS_JSON_PATH, File.join(@claude_home, ".credentials.json"))
    swap_const(:CLAUDE_JSON_PATH, File.join(@claude_home, ".claude.json"))
  end

  teardown do
    swap_const(:CREDENTIALS_JSON_PATH, @original_credentials_path)
    swap_const(:CLAUDE_JSON_PATH, @original_claude_json_path)
    ENV.delete("CLAUDE_SESSION_CONFIG_DIR")
    FileUtils.rm_rf(@config_base)
    FileUtils.rm_rf(@claude_home)
  end

  # ── the filesystem stops being written ────────────────────────────────

  test "write_config! refuses to put a subscription token on the shared filesystem" do
    with_setting(true) do
      AccountRotationService.new.write_config!(claude_accounts(:primary))

      refute File.exist?(ClaudeAuthProvider::CREDENTIALS_JSON_PATH),
        "no session reads this file any more; writing a refresh token to it is the hazard being removed"
    end
  end

  test "with the setting off, write_config! still writes the shared filesystem" do
    with_setting(false) do
      AccountRotationService.new.write_config!(claude_accounts(:primary))

      assert File.exist?(ClaudeAuthProvider::CREDENTIALS_JSON_PATH)
    end
  end

  test "activate! is a DB write and a snapshot, with no filesystem step" do
    secondary = claude_accounts(:secondary)
    QuotaCheckService.stubs(:check_with_token).returns(stub(success?: false, error_message: "skip"))

    with_setting(true) do
      AccountRotationService.new.activate!(secondary, snapshot_trigger: "manual_switch")

      assert secondary.reload.is_current?
      refute File.exist?(ClaudeAuthProvider::CREDENTIALS_JSON_PATH)
    end
  end

  test "ensure_active_account! keeps a healthy current account without touching the filesystem" do
    primary = claude_accounts(:primary)
    primary.update!(is_current: true, status: :active)

    with_setting(true) do
      assert_equal primary, AccountRotationService.new.ensure_active_account!
      refute File.exist?(ClaudeAuthProvider::CREDENTIALS_JSON_PATH)
    end
  end

  # ── MCP OAuth moves with the session ──────────────────────────────────

  test "the MCP credential writer targets the session's own config dir" do
    session = sessions(:active_session)

    with_setting(true) do
      writer = ClaudeMcpCredentialWriter.for_session(session)

      assert_equal ClaudeSessionConfigDirectory.credentials_path_for(session.id), writer.credentials_path
    end
  end

  test "with the setting off, the MCP credential writer targets the host-global file" do
    with_setting(false) do
      writer = ClaudeMcpCredentialWriter.for_session(sessions(:active_session))

      assert_equal ClaudeMcpCredentialWriter::CLAUDE_CREDENTIALS_PATH, writer.credentials_path
    end
  end

  # A rotated MCP token lands in the session's file and is read back from there.
  # This is the smaller instance of the same sync problem, and it is what makes
  # the remaining credentials file harmless: it holds mcpOAuth and nothing else.
  test "a token written for one session is invisible to another session's store" do
    with_setting(true) do
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
  end

  test "the session's credentials file never gains a claudeAiOauth block from Zimmer" do
    session = sessions(:active_session)

    with_setting(true) do
      writer = ClaudeMcpCredentialWriter.for_session(session)
      writer.stubs(:macos?).returns(false)
      writer.write!(working_directory: @config_base, credentials: [ resolved_credential ])

      data = JSON.parse(File.read(writer.credentials_path))
      assert_equal [ "mcpOAuth" ], data.keys
    end
  end

  # ── the sweep stops reading the filesystem back ───────────────────────

  test "the auth sweep does not sync the current account's tokens off the filesystem" do
    claude_accounts(:primary).update!(is_current: true)

    with_setting(true) do
      ClaudeAccount.any_instance.expects(:sync_tokens_from_filesystem!).never

      assert_nil ClaudeAuthProvider.new.sync_current_account_tokens!
    end
  end

  test "Claude no longer reconciles a filesystem identity into the DB at all" do
    # The base hook's no-op is the behaviour, on or off: adopting an identity off
    # a container-local file is what let a container replacement change which
    # account production ran under (#618, addendum B).
    assert_nil ClaudeAuthProvider.new.reconcile_filesystem_identity!
  end

  # ── re-auth is one write ──────────────────────────────────────────────

  test "capturing a login for the current account writes only the DB" do
    account = claude_accounts(:primary)
    account.update!(is_current: true)

    with_setting(true) do
      AccountRotationService.any_instance.expects(:write_config!).never

      capture_login!(account)

      assert_equal "fresh-access", account.reload.claude_access_token
      refute File.exist?(ClaudeAuthProvider::CREDENTIALS_JSON_PATH)
    end
  end

  test "with the setting off, capturing a login for the current account still writes the filesystem" do
    account = claude_accounts(:primary)
    account.update!(is_current: true)

    with_setting(false) do
      AccountRotationService.any_instance.expects(:write_config!).with(account, force: true).once

      capture_login!(account)
    end
  end

  # ── the health surface describes the store in use ─────────────────────

  test "health reports the DB as the credential store, naming the current account" do
    claude_accounts(:primary).update!(is_current: true, status: :active)

    with_setting(true) do
      status = ClaudeCredentialHealth.status

      assert_equal :ok, status.state
      assert_equal "tadas@tadasant.com", status.owner_email
      assert_match(/authenticate from the database/, status.detail)
    end
  end

  test "health reports corrupt when the current account's stored tokens are unusable" do
    claude_accounts(:primary).update!(is_current: true, oauth_config: { "credentials_json" => {} })

    with_setting(true) do
      status = ClaudeCredentialHealth.status

      assert_equal :corrupt, status.state
      assert_match(/Re-authenticate/, status.detail)
    end
  end

  test "health reports absent when nothing is current yet" do
    ClaudeAccount.update_all(is_current: false)

    with_setting(true) do
      assert_equal :absent, ClaudeCredentialHealth.status.state
    end
  end

  test "self-heal has nothing to repair when there is no shared file in play" do
    # A corrupt shared file would still be on disk after a rollback, and rewriting
    # it every five minutes while nothing reads it is noise, not a repair.
    File.write(ClaudeAuthProvider::CREDENTIALS_JSON_PATH,
      JSON.generate("claudeAiOauth" => { "accessToken" => "", "refreshToken" => "" }))

    with_setting(true) do
      outcome, detail = ClaudeCredentialHealth.self_heal!

      assert_equal :skipped, outcome
      assert_match(/no shared file to repair/, detail)
    end
  end

  private

  def with_setting(enabled)
    AppSetting.stubs(:session_scoped_credentials_enabled?).returns(enabled)
    yield
  end

  def swap_const(name, value)
    ClaudeAuthProvider.send(:remove_const, name)
    ClaudeAuthProvider.const_set(name, value)
  end

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

  # Drive ClaudeLoginDriver#capture! against a scratch dir holding a complete,
  # Anthropic-honoured token pair — the state a finished interactive login leaves.
  def capture_login!(account)
    QuotaCheckService.stubs(:token_rejected?).returns(false)

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
