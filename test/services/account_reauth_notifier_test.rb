# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class AccountReauthNotifierTest < ActiveSupport::TestCase
  setup do
    @account = claude_accounts(:primary)
    @account.update_columns(status: ClaudeAccount.statuses[:needs_reauth])
    @account.reload
    # `notify` asks the gate before composing, and `test` is not an alerting
    # environment. These cases are about what the DM says, not about the gate.
    AlertService.stubs(:enabled?).returns(true)
  end

  test "dedup_key is per account, so two dead accounts produce two DMs" do
    other = claude_accounts(:secondary)

    assert_not_equal AccountReauthNotifier.dedup_key(@account),
      AccountReauthNotifier.dedup_key(other)
    assert_includes AccountReauthNotifier.dedup_key(@account), @account.id.to_s
  end

  test "notify DMs the operator naming the account and pointing at /quotas" do
    AlertService.expects(:dm_operator).with { |title, opts|
      title.include?("needs re-authentication") &&
        opts[:details].include?(@account.email) &&
        opts[:details].include?("/quotas") &&
        opts[:dedup_key] == AccountReauthNotifier.dedup_key(@account) &&
        opts[:source] == "ClaudeAccount"
    }.returns(true)

    assert AccountReauthNotifier.notify(@account)
  end

  test "notify names the runtime so a Codex account is not mistaken for a Claude one" do
    @account.update_columns(runtime: "codex")
    @account.reload

    AlertService.expects(:dm_operator).with { |title, _opts| title.start_with?("Codex ") }.returns(true)

    AccountReauthNotifier.notify(@account)
  end

  test "notify says Claude for a claude_code account" do
    AlertService.expects(:dm_operator).with { |title, _opts| title.start_with?("Claude ") }.returns(true)

    AccountReauthNotifier.notify(@account)
  end

  test "notify sends nothing when the account has since recovered" do
    @account.update_columns(status: ClaudeAccount.statuses[:active])
    @account.reload

    AlertService.expects(:dm_operator).never

    assert_not AccountReauthNotifier.notify(@account)
  end

  test "notify composes nothing on an instance that may not page" do
    AlertService.stubs(:enabled?).returns(false)
    # details_for walks the secret-provider chain to build the /quotas link.
    # A gated instance -- development, and every agent clone -- must not pay for
    # a DM it will immediately drop.
    AppUrl.expects(:base_url).never
    AlertService.expects(:dm_operator).never

    assert_not AccountReauthNotifier.notify(@account)
  end

  test "clear drops the suppression for that account only" do
    AlertService.expects(:clear_dm_suppression).with(AccountReauthNotifier.dedup_key(@account))

    AccountReauthNotifier.clear(@account)
  end

  test "the details body carries the absolute quotas URL, not a bare path" do
    AppUrl.stubs(:base_url).returns("https://zimmer.example.com")

    AlertService.expects(:dm_operator).with { |_title, opts|
      opts[:details].include?("https://zimmer.example.com/quotas")
    }.returns(true)

    AccountReauthNotifier.notify(@account)
  end

  test "a trailing slash on the base URL does not produce a doubled slash" do
    AppUrl.stubs(:base_url).returns("https://zimmer.example.com/")

    AlertService.expects(:dm_operator).with { |_title, opts|
      opts[:details].include?("https://zimmer.example.com/quotas") &&
        !opts[:details].include?("//quotas")
    }.returns(true)

    AccountReauthNotifier.notify(@account)
  end
end
