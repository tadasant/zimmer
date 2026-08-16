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

  test "crossing into needs_reauth enqueues the operator DM" do
    assert_enqueued_with(job: AccountReauthAlertJob, args: [ @account.id ]) do
      @account.update!(status: :needs_reauth)
    end
  end

  # The regression test for the gap the fresh-eyes review found: the bare
  # `update!` above passes even when the every-5-minutes refresh sweep — the
  # likeliest discoverer of a dead refresh token — cannot alert at all.
  #
  # RefreshRuntimeAuthTokensJob wraps the refresh in an OUTER `account.with_lock`,
  # and ClaudeAuthProvider#refresh! reloads on its failure branch to classify the
  # error. `with_lock` opens a transaction without `requires_new`, so the write
  # and the reload land in one transaction and the commit callback fires only
  # after both. `reload` nils the dirty state, so a commit-time
  # `saved_change_to_status?` sees nothing and the DM is skipped.
  #
  # Driven through the real ClaudeAuthProvider#refresh! and the real nesting, so
  # that a future change which reintroduces the commit-time dirty read fails here.
  test "the refresh sweep's reload-inside-the-transaction still alerts" do
    account = @account
    account.stubs(:refresh_token!).returns(false)

    assert_enqueued_with(job: AccountReauthAlertJob, args: [ account.id ]) do
      account.with_lock do
        # What perform_claude_refresh!'s permanent-failure branch does, inside the
        # lock the provider call is nested in.
        account.update!(status: :needs_reauth)

        # ...and this is the reload that used to erase the evidence of it.
        result = ClaudeAuthProvider.new.refresh!(account)
        assert_not result.ok?
        assert_equal :needs_reauth, result.error
      end
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
  #
  # Driven through the real provider rather than by hand-rolling the two writes,
  # so that switching it to `update!` some day fails HERE rather than silently
  # turning the recovery sweep into a DM source.
  test "a failed recovery sweep does not re-alert" do
    @account.update_columns(status: ClaudeAccount.statuses[:needs_reauth])
    ClaudeAccount.any_instance.stubs(:can_refresh_token?).returns(true)
    ClaudeAccount.any_instance.stubs(:refresh_token!).returns(false)

    assert_no_enqueued_jobs(only: AccountReauthAlertJob) do
      assert_not ClaudeAuthProvider.new.recover_needs_reauth(@account)
    end
    assert_predicate @account.reload, :needs_reauth?
  end

  test "the codex recovery sweep does not re-alert either" do
    codex = ClaudeAccount.create!(email: "codex-recover@example.com", runtime: "codex")
    codex.update_columns(status: ClaudeAccount.statuses[:needs_reauth])
    ClaudeAccount.any_instance.stubs(:can_refresh_token?).returns(true)
    ClaudeAccount.any_instance.stubs(:refresh_token!).returns(false)

    assert_no_enqueued_jobs(only: AccountReauthAlertJob) do
      assert_not CodexAuthProvider.new.recover_needs_reauth(codex)
    end
  end

  # The suppression is NOT cleared by the status callback. sync_from_filesystem!
  # resurrects the on-disk owner to `active` with a plain update!, and
  # ensure_active_account! runs it before every session spawn — so clearing there
  # would drop the backstop moments before usable_candidate? re-condemns the same
  # account, which is one DM per spawn attempt on a drained pool.
  test "leaving needs_reauth does not clear the suppression on its own" do
    @account.update!(status: :needs_reauth)

    AccountReauthNotifier.expects(:clear).never

    @account.update!(status: :active)
  end

  # QuotasController seeds a credential-less new account straight into
  # needs_reauth. The human is on /quotas adding it; telling them to go to
  # /quotas is noise.
  test "creating an account in needs_reauth does not DM" do
    assert_no_enqueued_jobs(only: AccountReauthAlertJob) do
      ClaudeAccount.create!(email: "fresh@example.com", status: :needs_reauth)
    end
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
