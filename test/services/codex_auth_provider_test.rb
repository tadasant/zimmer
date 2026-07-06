# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# Tests CodexAuthProvider: the concrete RuntimeAuthProvider for the OpenAI Codex
# CLI. The provider is a seam over the ClaudeAccount pool (scoped to the "codex"
# runtime) plus self-contained ~/.codex/auth.json filesystem reconciliation and
# quota rotation. These tests verify the provider contract and that it drives the
# pool correctly; the model's Codex token internals have their own coverage in
# claude_account_test.rb.
class CodexAuthProviderTest < ActiveSupport::TestCase
  setup do
    @provider = CodexAuthProvider.new

    # Redirect ~/.codex to a temp dir so writes/reads never touch the real
    # filesystem or leak across tests.
    @tmpdir = Dir.mktmpdir
    @original_codex_home = CodexAuthProvider::CODEX_HOME
    @original_auth_json_path = CodexAuthProvider::AUTH_JSON_PATH
    CodexAuthProvider.send(:remove_const, :CODEX_HOME)
    CodexAuthProvider.const_set(:CODEX_HOME, @tmpdir)
    CodexAuthProvider.send(:remove_const, :AUTH_JSON_PATH)
    CodexAuthProvider.const_set(:AUTH_JSON_PATH, File.join(@tmpdir, "auth.json"))
  end

  teardown do
    FileUtils.rm_rf(@tmpdir)
    CodexAuthProvider.send(:remove_const, :CODEX_HOME)
    CodexAuthProvider.const_set(:CODEX_HOME, @original_codex_home)
    CodexAuthProvider.send(:remove_const, :AUTH_JSON_PATH)
    CodexAuthProvider.const_set(:AUTH_JSON_PATH, @original_auth_json_path)
  end

  test "runtime is codex" do
    assert_equal "codex", @provider.runtime
  end

  test "accounts is the pool scoped to the codex runtime" do
    accounts = @provider.accounts
    assert accounts.exists?
    assert accounts.all? { |a| a.runtime == "codex" }
    assert_includes accounts, claude_accounts(:codex_primary)
  end

  test "accounts excludes claude_code accounts" do
    refute_includes @provider.accounts, claude_accounts(:primary)
  end

  test "current_account returns the is_current codex account" do
    assert_equal claude_accounts(:codex_primary), @provider.current_account
  end

  test "current_account is independent of the claude_code current account" do
    # The Claude pool's current account must not leak into the Codex pool.
    assert_equal claude_accounts(:codex_primary), @provider.current_account
    assert_equal claude_accounts(:primary), ClaudeAccount.current_account("claude_code")
  end

  test "select_account_for returns the current account when one is active" do
    assert_equal claude_accounts(:codex_primary), @provider.select_account_for(nil)
  end

  test "select_account_for falls back to the next available codex account" do
    ClaudeAccount.for_runtime("codex").update_all(is_current: false)
    selected = @provider.select_account_for(nil)
    assert selected.active?
    assert_equal "codex", selected.runtime
    assert_equal claude_accounts(:codex_primary), selected
  end

  test "rotation_interval is 24 hours" do
    assert_equal 24.hours, @provider.rotation_interval
  end

  test "refresh! is an ok no-op for API-key accounts and makes no network call" do
    account = claude_accounts(:codex_api_key)
    assert account.codex_api_key_account?
    account.expects(:refresh_token!).never

    result = @provider.refresh!(account)
    assert result.ok?
    assert_nil result.error
  end

  test "refresh! returns an ok Result when the token refresh succeeds" do
    account = claude_accounts(:codex_primary)
    account.stubs(:refresh_token!).returns(true)

    result = @provider.refresh!(account)
    assert result.ok?
    assert_nil result.error
  end

  test "refresh! reports :transient when refresh fails but the account is still active" do
    account = claude_accounts(:codex_primary)
    account.stubs(:refresh_token!).returns(false)
    account.stubs(:reload).returns(account)
    account.stubs(:needs_reauth?).returns(false)

    result = @provider.refresh!(account)
    refute result.ok?
    assert_equal :transient, result.error
  end

  test "refresh! reports :needs_reauth when the account is permanently invalid" do
    account = claude_accounts(:codex_primary)
    account.stubs(:refresh_token!).returns(false)
    account.stubs(:reload).returns(account)
    account.stubs(:needs_reauth?).returns(true)

    result = @provider.refresh!(account)
    refute result.ok?
    assert_equal :needs_reauth, result.error
  end

  test "inject_for_session! writes the current account's auth.json and returns it" do
    # codex_primary has a recent last_refresh, so no token refresh fires.
    account = @provider.inject_for_session!(nil, "/tmp/clone")

    assert_equal claude_accounts(:codex_primary), account
    assert File.exist?(CodexAuthProvider::AUTH_JSON_PATH)
    written = JSON.parse(File.read(CodexAuthProvider::AUTH_JSON_PATH))
    assert_equal "codex_account_1", written.dig("tokens", "account_id")
  end

  test "inject_for_session! bootstraps the first available account when none is current" do
    ClaudeAccount.for_runtime("codex").update_all(is_current: false)

    account = @provider.inject_for_session!(nil, "/tmp/clone")

    assert_equal claude_accounts(:codex_primary), account
    assert account.reload.is_current?
    assert File.exist?(CodexAuthProvider::AUTH_JSON_PATH)
  end

  test "rotate_for_quota! marks the current account quota_exceeded and activates the next" do
    # Stub token validation so activate_next_account doesn't hit the network.
    ClaudeAccount.any_instance.stubs(:refresh_token!).returns(true)

    result = @provider.rotate_for_quota!(triggered_by: "session:99")

    assert result[:success]
    assert_equal claude_accounts(:codex_secondary), result[:account]
    assert claude_accounts(:codex_primary).reload.quota_exceeded?
    assert claude_accounts(:codex_secondary).reload.is_current?

    written = JSON.parse(File.read(CodexAuthProvider::AUTH_JSON_PATH))
    assert_equal "codex_account_2", written.dig("tokens", "account_id")

    event = AccountRotationEvent.order(:created_at).last
    assert_equal claude_accounts(:codex_primary), event.rotated_from
    assert_equal claude_accounts(:codex_secondary), event.rotated_to
    assert_equal "quota_exceeded", event.reason
  end

  test "rotate_for_quota! returns no_available_accounts when the pool is exhausted" do
    # Leave only the current account; everything else unavailable.
    claude_accounts(:codex_secondary).update!(status: :quota_exceeded)
    claude_accounts(:codex_api_key).update!(status: :quota_exceeded)

    result = @provider.rotate_for_quota!(triggered_by: nil)

    refute result[:success]
    assert_equal "no_available_accounts", result[:reason]
    assert claude_accounts(:codex_primary).reload.quota_exceeded?
  end

  test "rotate_for_quota! activates an API-key account without a network probe" do
    # Make the API-key account the only candidate after the current.
    claude_accounts(:codex_secondary).update!(status: :quota_exceeded)
    ClaudeAccount.any_instance.expects(:refresh_token!).never

    result = @provider.rotate_for_quota!(triggered_by: nil)

    assert result[:success]
    assert_equal claude_accounts(:codex_api_key), result[:account]
    written = JSON.parse(File.read(CodexAuthProvider::AUTH_JSON_PATH))
    assert_equal "sk-codex-test-key", written["OPENAI_API_KEY"]
  end

  test "recover_needs_reauth returns false for an account that is not in needs_reauth" do
    refute @provider.recover_needs_reauth(claude_accounts(:codex_primary))
  end

  test "recover_needs_reauth recovers a needs_reauth account whose refresh succeeds" do
    account = claude_accounts(:codex_secondary)
    account.update!(status: :needs_reauth)
    account.stubs(:can_refresh_token?).returns(true)
    account.stubs(:refresh_token!).returns(true)

    assert @provider.recover_needs_reauth(account)
  end

  test "recover_needs_reauth leaves the account in needs_reauth when refresh fails" do
    account = claude_accounts(:codex_secondary)
    account.update!(status: :needs_reauth)
    account.stubs(:can_refresh_token?).returns(true)
    account.stubs(:refresh_token!).returns(false)

    refute @provider.recover_needs_reauth(account)
    assert account.reload.needs_reauth?
  end

  test "needs_reauth_recovery_candidates returns codex accounts with a refresh token" do
    claude_accounts(:codex_secondary).update!(status: :needs_reauth)

    candidates = @provider.needs_reauth_recovery_candidates
    assert_includes candidates, claude_accounts(:codex_secondary)
    # API-key accounts have nothing to refresh and are never candidates.
    refute candidates.any? { |a| a.email == claude_accounts(:codex_api_key).email }
  end
end
