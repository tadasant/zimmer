# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class AccountReauthAlertJobTest < ActiveSupport::TestCase
  test "notifies for the account it was enqueued with" do
    account = claude_accounts(:primary)
    account.update_columns(status: ClaudeAccount.statuses[:needs_reauth])

    AccountReauthNotifier.expects(:notify).with { |acct| acct.id == account.id }.returns(true)

    AccountReauthAlertJob.perform_now(account.id)
  end

  # The account can be deleted between the transition and the job running.
  test "does nothing when the account is gone" do
    AccountReauthNotifier.expects(:notify).never

    assert_nothing_raised { AccountReauthAlertJob.perform_now(-1) }
  end
end
