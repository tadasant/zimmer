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
  Measure = Data.define(:five_hour, :weekly, :worst_five_hour, :worst_weekly,
                        :account_count, :read_count, :weekly_spent_count) do
    # True when at least one account had something to say.
    def any_readings? = read_count.positive?
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
      weekly_spent_count += 1 if snapshot.seven_day_window_spent?
    end

    Measure.new(
      five_hour: average(fives), weekly: average(weeklies),
      worst_five_hour: fives.max, worst_weekly: weeklies.max,
      account_count: @accounts.size, read_count: read_count,
      weekly_spent_count: weekly_spent_count
    )
  end

  private

  def average(values)
    return nil if values.empty?

    values.sum / values.size
  end
end
