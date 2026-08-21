# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# The needs_reauth alert hangs off ClaudeAccount's status transition rather than
# off the call sites that condemn an account, so what these cover is which writes
# count as a transition — and, just as importantly, which deliberately do not.
#
# What the transition emits is now the `account_needs_reauth` Zimmer event, which
# a Trigger turns into a Slack DM by spawning an agent session. Zimmer no longer
# composes the DM itself.
class ClaudeAccountNeedsReauthTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  EVENT = "account_needs_reauth"

  setup do
    @account = claude_accounts(:primary)
  end

  test "crossing into needs_reauth emits the account_needs_reauth event" do
    assert_enqueued_with(job: AoEventTriggerJob, args: [ EVENT, @account.id ]) do
      @account.update!(status: :needs_reauth)
    end
  end

  test "the event goes out on the latency-sensitive triggers queue" do
    assert_enqueued_with(job: AoEventTriggerJob, queue: "triggers") do
      @account.update!(status: :needs_reauth)
    end
  end

  # The regression test for the gap the fresh-eyes review found when this alert
  # was first built: the bare `update!` above passes even when the every-5-minutes
  # refresh sweep — the likeliest discoverer of a dead refresh token — cannot
  # alert at all.
  #
  # RefreshRuntimeAuthTokensJob wraps the refresh in an OUTER `account.with_lock`,
  # and ClaudeAuthProvider#refresh! reloads on its failure branch to classify the
  # error. `with_lock` opens a transaction without `requires_new`, so the write
  # and the reload land in one transaction and the commit callback fires only
  # after both. `reload` nils the dirty state, so a commit-time
  # `saved_change_to_status?` sees nothing and the alert is skipped.
  #
  # Driven through the real ClaudeAuthProvider#refresh! and the real nesting, so
  # that a future change which reintroduces the commit-time dirty read fails here.
  test "the refresh sweep's reload-inside-the-transaction still alerts" do
    account = @account
    account.stubs(:refresh_token!).returns(false)

    assert_enqueued_with(job: AoEventTriggerJob, args: [ EVENT, account.id ]) do
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

  test "a save that does not touch status emits nothing" do
    assert_no_enqueued_jobs(only: AoEventTriggerJob) do
      @account.update!(priority: 7)
    end
  end

  test "re-saving an account already in needs_reauth emits nothing" do
    @account.update!(status: :needs_reauth)

    assert_no_enqueued_jobs(only: AoEventTriggerJob) do
      @account.update!(priority: 9)
    end
  end

  # ClaudeAuthProvider#recover_needs_reauth flips an already-dead account to
  # active so refresh_token! is not status-blocked, then writes needs_reauth back
  # with update_columns when the probe fails. That restore is a no-op round trip
  # on an account that was already dead — if it alerted, every recovery sweep
  # would look like a fresh failure.
  #
  # Driven through the real provider rather than by hand-rolling the two writes,
  # so that switching it to `update!` some day fails HERE rather than silently
  # turning the recovery sweep into an alert source.
  test "a failed recovery sweep does not re-alert" do
    @account.update_columns(status: ClaudeAccount.statuses[:needs_reauth])
    ClaudeAccount.any_instance.stubs(:can_refresh_token?).returns(true)
    ClaudeAccount.any_instance.stubs(:refresh_token!).returns(false)

    assert_no_enqueued_jobs(only: AoEventTriggerJob) do
      assert_not ClaudeAuthProvider.new.recover_needs_reauth(@account)
    end
    assert_predicate @account.reload, :needs_reauth?
  end

  test "the codex recovery sweep does not re-alert either" do
    codex = ClaudeAccount.create!(email: "codex-recover@example.com", runtime: "codex")
    codex.update_columns(status: ClaudeAccount.statuses[:needs_reauth])
    ClaudeAccount.any_instance.stubs(:can_refresh_token?).returns(true)
    ClaudeAccount.any_instance.stubs(:refresh_token!).returns(false)

    assert_no_enqueued_jobs(only: AoEventTriggerJob) do
      assert_not CodexAuthProvider.new.recover_needs_reauth(codex)
    end
  end

  # QuotasController seeds a credential-less new account straight into
  # needs_reauth. The human is on /quotas adding it; telling them to go to
  # /quotas is noise.
  test "creating an account in needs_reauth does not alert" do
    assert_no_enqueued_jobs(only: AoEventTriggerJob) do
      ClaudeAccount.create!(email: "fresh@example.com", status: :needs_reauth)
    end
  end

  test "an alert dispatch failure never breaks the status write" do
    AoEventTriggerJob.stubs(:perform_later).raises(StandardError.new("queue down"))

    assert_nothing_raised { @account.update!(status: :needs_reauth) }
    assert_predicate @account.reload, :needs_reauth?
  end

  test "a codex account transition alerts too" do
    codex = ClaudeAccount.create!(email: "codex@example.com", runtime: "codex")

    assert_enqueued_with(job: AoEventTriggerJob, args: [ EVENT, codex.id ]) do
      codex.update!(status: :needs_reauth)
    end
  end

  # === The repeat throttle ===
  #
  # An account crosses INTO needs_reauth far more often than it breaks:
  # sync_from_filesystem! writes `active` back onto a dead row whose credentials
  # file still parses, and ensure_active_account! runs it before every session
  # spawn. Under the old design each crossing was a candidate DM; under this one
  # each would spawn an agent session, so the throttle is load-bearing.

  test "a second crossing inside the window emits nothing" do
    @account.update!(status: :needs_reauth)
    @account.update!(status: :active)

    assert_no_enqueued_jobs(only: AoEventTriggerJob) do
      @account.update!(status: :needs_reauth)
    end
  end

  test "a crossing after the window elapses emits again" do
    @account.update!(status: :needs_reauth)
    @account.update_columns(reauth_alerted_at: (ClaudeAccount::REAUTH_ALERT_THROTTLE + 1.hour).ago)
    @account.update!(status: :active)

    assert_enqueued_with(job: AoEventTriggerJob, args: [ EVENT, @account.id ]) do
      @account.update!(status: :needs_reauth)
    end
  end

  test "the throttle is stamped on the row, not held in a cache" do
    freeze_time do
      @account.update!(status: :needs_reauth)
      assert_equal Time.current, @account.reload.reauth_alerted_at
    end
  end

  # Only a human completing a login releases it. Everything else that writes
  # `active` is machinery, and releasing on machinery is what turns a drained pool
  # into one spawned session per spawn attempt.
  test "leaving needs_reauth does not release the throttle on its own" do
    @account.update!(status: :needs_reauth)
    stamped = @account.reload.reauth_alerted_at
    assert_not_nil stamped

    @account.update!(status: :active)

    assert_equal stamped, @account.reload.reauth_alerted_at
  end

  test "clear_reauth_alert! releases it, so the next failure alerts immediately" do
    @account.update!(status: :needs_reauth)
    @account.update!(status: :active)
    @account.clear_reauth_alert!

    assert_nil @account.reload.reauth_alerted_at
    assert_enqueued_with(job: AoEventTriggerJob, args: [ EVENT, @account.id ]) do
      @account.update!(status: :needs_reauth)
    end
  end

  # Two workers can condemn the same account in the same instant — the refresh
  # sweep and a spawn-time usability check, for instance. The claim is a single
  # conditional UPDATE precisely so only one of them wins.
  test "concurrent claims on one account yield exactly one event" do
    claims = 5.times.map { ClaudeAccount.find(@account.id).send(:claim_reauth_alert_slot!) }

    assert_equal 1, claims.count(true), "expected exactly one winner, got #{claims.inspect}"
  end
end
