# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# The operator DM hangs off ClaudeAccount's status transition rather than off the
# call sites that condemn an account, so what these cover is which writes count
# as a transition — and, just as importantly, which deliberately do not.
class ClaudeAccountNeedsReauthTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @account = claude_accounts(:primary)
  end

  teardown do
    Mocha::Mockery.instance.teardown
  end

  test "crossing into needs_reauth enqueues the operator DM" do
    assert_enqueued_with(job: AccountReauthAlertJob, args: [ @account.id ]) do
      @account.update!(status: :needs_reauth)
    end
  end

  test "a save that does not touch status enqueues nothing" do
    assert_no_enqueued_jobs(only: AccountReauthAlertJob) do
      @account.update!(priority: 7)
    end
  end

  test "re-saving an account already in needs_reauth enqueues nothing" do
    @account.update!(status: :needs_reauth)

    assert_no_enqueued_jobs(only: AccountReauthAlertJob) do
      @account.update!(priority: 9)
    end
  end

  # ClaudeAuthProvider#recover_needs_reauth flips an already-dead account to
  # active so refresh_token! is not status-blocked, then writes needs_reauth back
  # with update_columns when the probe fails. That restore is a no-op round trip
  # on an account that was already dead — if it alerted, every recovery sweep
  # would look like a fresh failure and re-nag on the dedup window's clock.
  test "the recovery path's update_columns restore does not re-alert" do
    @account.update_columns(status: ClaudeAccount.statuses[:needs_reauth])

    assert_no_enqueued_jobs(only: AccountReauthAlertJob) do
      @account.update_columns(status: ClaudeAccount.statuses[:active])
      @account.update_columns(status: ClaudeAccount.statuses[:needs_reauth])
    end
  end

  # QuotasController seeds a credential-less new account straight into
  # needs_reauth. The human is on /quotas adding it; telling them to go to
  # /quotas is noise.
  test "creating an account in needs_reauth does not DM" do
    assert_no_enqueued_jobs(only: AccountReauthAlertJob) do
      ClaudeAccount.create!(email: "fresh@example.com", status: :needs_reauth)
    end
  end

  test "leaving needs_reauth clears the suppression so a later failure still alerts" do
    @account.update!(status: :needs_reauth)

    AccountReauthNotifier.expects(:clear).with { |acct| acct.id == @account.id }

    @account.update!(status: :active)
  end

  test "an alert dispatch failure never breaks the status write" do
    AccountReauthAlertJob.stubs(:perform_later).raises(StandardError.new("queue down"))

    assert_nothing_raised { @account.update!(status: :needs_reauth) }
    assert_predicate @account.reload, :needs_reauth?
  end

  test "a codex account transition alerts too" do
    codex = ClaudeAccount.create!(email: "codex@example.com", runtime: "codex")

    assert_enqueued_with(job: AccountReauthAlertJob, args: [ codex.id ]) do
      codex.update!(status: :needs_reauth)
    end
  end
end
