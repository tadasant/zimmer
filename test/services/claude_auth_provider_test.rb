# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# Tests ClaudeAuthProvider: the concrete RuntimeAuthProvider for Claude Code.
# The provider is a thin seam over ClaudeAccount (the pool) and
# AccountRotationService (filesystem ↔ DB reconciliation); these tests verify the
# provider contract and that it delegates to those workhorses, not their internals
# (which have their own dedicated test files).
class ClaudeAuthProviderTest < ActiveSupport::TestCase
  setup do
    @provider = ClaudeAuthProvider.new
  end

  test "runtime is claude_code" do
    assert_equal "claude_code", @provider.runtime
  end

  test "accounts is the pool scoped to the claude_code runtime" do
    accounts = @provider.accounts
    assert accounts.exists?
    assert accounts.all? { |a| a.runtime == "claude_code" }
    assert_includes accounts, claude_accounts(:primary)
  end

  test "accounts excludes other runtimes" do
    other = claude_accounts(:secondary)
    other.update_column(:runtime, "codex")
    refute_includes @provider.accounts, other
  end

  test "current_account returns the is_current account" do
    assert_equal claude_accounts(:primary), @provider.current_account
  end

  test "select_account_for returns the current account when one is active" do
    assert_equal claude_accounts(:primary), @provider.select_account_for(nil)
  end

  test "select_account_for falls back to the next available account" do
    ClaudeAccount.update_all(is_current: false)
    selected = @provider.select_account_for(nil)
    assert selected.active?
    assert selected.oauth_config.present?
    # available is ordered by priority; primary (priority 0) is the first.
    assert_equal claude_accounts(:primary), selected
  end

  test "rotation_interval is five minutes" do
    assert_equal 5.minutes, @provider.rotation_interval
  end

  test "refresh! returns an ok Result when the token refresh succeeds" do
    account = claude_accounts(:primary)
    account.stubs(:refresh_token!).returns(true)

    result = @provider.refresh!(account)
    assert result.ok?
    assert_nil result.error
  end

  test "refresh! reports :transient when refresh fails but the account is still active" do
    account = claude_accounts(:primary)
    account.stubs(:refresh_token!).returns(false)
    account.stubs(:reload).returns(account)
    account.stubs(:needs_reauth?).returns(false)

    result = @provider.refresh!(account)
    refute result.ok?
    assert_equal :transient, result.error
  end

  test "refresh! reports :needs_reauth when the account is permanently invalid" do
    account = claude_accounts(:primary)
    account.stubs(:refresh_token!).returns(false)
    account.stubs(:reload).returns(account)
    account.stubs(:needs_reauth?).returns(true)

    result = @provider.refresh!(account)
    refute result.ok?
    assert_equal :needs_reauth, result.error
  end

  test "inject_for_session! delegates to AccountRotationService#ensure_active_account!" do
    account = claude_accounts(:primary)
    AccountRotationService.any_instance.expects(:ensure_active_account!).returns(account)
    assert_equal account, @provider.inject_for_session!(nil, "/tmp/clone")
  end

  test "rotate_for_quota! delegates to AccountRotationService#rotate! with the quota reason" do
    expected = { success: true, account: claude_accounts(:secondary) }
    AccountRotationService.any_instance
      .expects(:rotate!)
      .with(reason: "quota_exceeded", triggered_by: "session:42")
      .returns(expected)

    assert_equal expected, @provider.rotate_for_quota!(triggered_by: "session:42")
  end

  test "recover_needs_reauth returns false for an account that is not in needs_reauth" do
    refute @provider.recover_needs_reauth(claude_accounts(:primary))
  end

  test "recover_needs_reauth recovers a needs_reauth account whose refresh succeeds" do
    account = claude_accounts(:secondary)
    account.update!(status: :needs_reauth)
    account.stubs(:can_refresh_token?).returns(true)
    account.stubs(:refresh_token!).returns(true)

    assert @provider.recover_needs_reauth(account)
  end

  test "recover_needs_reauth leaves the account in needs_reauth when refresh fails" do
    account = claude_accounts(:secondary)
    account.update!(status: :needs_reauth)
    account.stubs(:can_refresh_token?).returns(true)
    account.stubs(:refresh_token!).returns(false)

    refute @provider.recover_needs_reauth(account)
    assert account.reload.needs_reauth?
  end
end
