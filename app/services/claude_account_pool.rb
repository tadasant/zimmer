# frozen_string_literal: true

# What the whole account pool is carrying right now, as one pair of numbers.
#
# There is exactly one of these because two surfaces act on it: the "Account
# Pool" section of /quotas renders it, and SpotGateService decides whether spot
# work runs on it. A second averaging written beside this one would drift, and
# the page would show a headline number the gate was not using.
#
# == Every account counts, whatever its status
#
# The pool is `ClaudeAccount.for_runtime` — active accounts, quota_exceeded ones,
# and accounts in needs_reauth alike. A needs_reauth account is one Zimmer cannot
# serve from *this minute*, not one whose quota has been spent: its window keeps
# draining while it waits for a human to re-authenticate, and the headroom is
# real again the moment they do. Leaving it out would shrink the denominator to
# the accounts that happen to be serving and make the average jump every time an
# account drops out or comes back.
#
# An account with no reading contributes nothing and is not counted in the
# denominator either — there is no number to average.
class ClaudeAccountPool
  # Both windows averaged across the pool, plus enough to say what was averaged.
  #
  # `read_count` is the accounts that contributed; `account_count` is the pool.
  # They differ when an account has never been probed, which is worth saying out
  # loud rather than quietly averaging over a smaller pool than the page shows.
  #
  # The two reset times answer "we're blocked until when?". Each is the soonest
  # reset that actually hands capacity back on its window, not the soonest reset
  # of that kind anywhere in the pool:
  #
  # - `next_five_hour_reset` looks only at accounts whose weekly allowance is
  #   still there. An account whose week is spent does not become servable when
  #   its 5-hour window rolls over, so counting its reset here would report the
  #   pool as recovering hours before it does — the same confusion the
  #   "effective" qualifier on the 5-hour average exists to prevent.
  # - `next_weekly_reset` looks only at accounts whose week IS spent, because
  #   those are the ones a 7-day rollover returns to service. When no account is
  #   weekly-blocked it is nil, which is the pool saying the week is not what
  #   holds it.
  #
  # Either is nil when nothing in that set carries a reset time still ahead of
  # us; a past timestamp describes a window that has already rolled over.
  Measure = Data.define(:five_hour, :weekly, :worst_five_hour, :worst_weekly,
                        :account_count, :read_count, :weekly_spent_count,
                        :next_five_hour_reset, :next_weekly_reset) do
    # True when at least one account had something to say.
    def any_readings? = read_count.positive?

    # Accounts with a reading whose weekly allowance is still there. These are
    # the only ones a 5-hour reset can hand capacity back to, which is what
    # `next_five_hour_reset` is measured over.
    def weekly_available_count = read_count - weekly_spent_count
  end

  class << self
    # The pool as it stands for `runtime`, loading the accounts and their latest
    # readings. Callers that already hold both (the /quotas render) build the
    # instance directly instead, to avoid re-querying what the page has loaded.
    def measure(runtime: ClaudeAuthProvider::RUNTIME)
      accounts = ClaudeAccount.for_runtime(runtime).to_a
      new(accounts: accounts, snapshots: latest_snapshots(accounts)).measure
    end

    # Each account's most recent reading, keyed by account id, in one query.
    # DISTINCT ON is Postgres doing the per-account "latest" that a Ruby-side
    # group_by would do a query at a time.
    def latest_snapshots(accounts)
      ClaudeAccountQuotaSnapshot
        .where(claude_account_id: accounts.map(&:id))
        .select("DISTINCT ON (claude_account_id) *")
        .order(:claude_account_id, created_at: :desc, id: :desc)
        .index_by(&:claude_account_id)
    end
  end

  # @param accounts [Array<ClaudeAccount>] the pool, every status included
  # @param snapshots [Hash{Integer => ClaudeAccountQuotaSnapshot}] latest reading
  #   per account id, as .latest_snapshots returns
  def initialize(accounts:, snapshots:)
    @accounts = accounts
    @snapshots = snapshots
  end

  def measure
    fives = []
    weeklies = []
    five_hour_resets = []
    weekly_resets = []
    read_count = 0
    weekly_spent_count = 0

    @accounts.each do |account|
      snapshot = @snapshots[account.id]
      next if snapshot.nil?

      five = snapshot.pool_utilization_5h
      weekly = snapshot.pool_utilization_7d
      # Neither window readable is a reading in name only: nothing to average,
      # and counting it would make the pool look better read than it is.
      next if five.nil? && weekly.nil?

      read_count += 1
      fives << five if five
      weeklies << weekly if weekly

      # An account is waiting on exactly one of the two windows. Its weekly
      # allowance is either gone — in which case only the 7-day reset returns
      # anything, and its 5-hour reset returns headroom nobody can spend — or it
      # is not, in which case the 5-hour window is the one that gates it.
      if snapshot.seven_day_window_spent?
        weekly_spent_count += 1
        weekly_resets << snapshot.reset_7d if pending?(snapshot.reset_7d)
      else
        five_hour_resets << snapshot.reset_5h if pending?(snapshot.reset_5h)
      end
    end

    Measure.new(
      five_hour: average(fives), weekly: average(weeklies),
      worst_five_hour: fives.max, worst_weekly: weeklies.max,
      account_count: @accounts.size, read_count: read_count,
      weekly_spent_count: weekly_spent_count,
      next_five_hour_reset: five_hour_resets.min,
      next_weekly_reset: weekly_resets.min
    )
  end

  private

  # A reset time still ahead of us. A timestamp in the past describes a window
  # that has already rolled over — the same rule
  # ClaudeAccountQuotaSnapshot.effective_utilization applies to the counter — so
  # it is not something the pool is waiting for.
  def pending?(reset_time)
    !reset_time.nil? && reset_time > Time.current
  end

  def average(values)
    return nil if values.empty?

    values.sum / values.size
  end
end
