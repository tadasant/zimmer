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
  # The two times answer "we're blocked until when?", from opposite ends.
  #
  # - `next_capacity_at` is the pool's answer: the soonest moment any account
  #   has room on *both* of its windows at once. An account is servable when the
  #   last of its spent windows rolls over, so per account it is the later of the
  #   two pending resets — a window that already has room contributes nothing,
  #   because that room is there now. Taking the earliest of those across the
  #   pool is when work starts moving again. It is nil when nothing is blocked
  #   (the pool has capacity this minute, and `capacity_now?` says so) and also
  #   nil when everything is blocked with no reset time recorded — the two are
  #   told apart by `capacity_now?`, not by the timestamp.
  # - `next_weekly_reset` looks only at accounts whose week IS spent, because
  #   those are the ones a 7-day rollover returns to service. When no account is
  #   weekly-blocked it is nil, which is the pool saying the week is not what
  #   holds it. It is the detail under the 7-day average, not the pool's answer:
  #   an account whose week returns at noon but whose 5-hour window is also spent
  #   until 2pm is not servable at noon.
  #
  # A past timestamp describes a window that has already rolled over, so neither
  # ever reports one.
  Measure = Data.define(:five_hour, :weekly, :worst_five_hour, :worst_weekly,
                        :account_count, :read_count, :weekly_spent_count,
                        :blocked_count, :next_capacity_at, :next_weekly_reset) do
    # True when at least one account had something to say.
    def any_readings? = read_count.positive?

    # Accounts with a reading that can serve a request this minute: room on the
    # 5-hour window and room on the 7-day one.
    def servable_count = read_count - blocked_count

    # True when the pool is not waiting on anything — there is capacity now, so
    # there is nothing for `next_capacity_at` to name.
    def capacity_now? = servable_count.positive?
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
    capacity_times = []
    weekly_resets = []
    read_count = 0
    weekly_spent_count = 0
    blocked_count = 0

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

      five_spent = snapshot.five_hour_window_spent?
      weekly_spent = snapshot.seven_day_window_spent?

      if weekly_spent
        weekly_spent_count += 1
        weekly_resets << snapshot.reset_7d if pending?(snapshot.reset_7d)
      end

      # Either window being spent takes the account out of service, and both
      # have to have room again before it comes back — which is why this is one
      # question about the account rather than two about its windows.
      next unless five_spent || weekly_spent

      blocked_count += 1
      servable_at = capacity_at(snapshot, five_spent: five_spent, weekly_spent: weekly_spent)
      capacity_times << servable_at if servable_at
    end

    # A pool that is serving has nothing to wait for. The moment a blocked
    # account rejoins is not when work resumes — work never stopped — so the
    # field stays nil and `capacity_now?` is what says which emptiness this is.
    serving_now = blocked_count < read_count

    Measure.new(
      five_hour: average(fives), weekly: average(weeklies),
      worst_five_hour: fives.max, worst_weekly: weeklies.max,
      account_count: @accounts.size, read_count: read_count,
      weekly_spent_count: weekly_spent_count,
      blocked_count: blocked_count,
      next_capacity_at: serving_now ? nil : capacity_times.min,
      next_weekly_reset: weekly_resets.min
    )
  end

  private

  # When an account carrying this reading can serve again: the later of the
  # resets it is actually waiting on. A window with room contributes nothing —
  # that room is available now — so an account blocked only by its week comes
  # back the moment the week does, whatever its 5-hour window is doing.
  #
  # nil when a window it is waiting on has no reset time recorded. A spent
  # window's reset is either that or still ahead of us — a timestamp in the past
  # describes a window that has already rolled over, which makes it not spent —
  # so the pending? check here is the nil case, stated as the invariant it is.
  # An account that cannot say when it returns must not set the pool's countdown.
  def capacity_at(snapshot, five_spent:, weekly_spent:)
    waiting_on = []
    waiting_on << snapshot.reset_5h if five_spent
    waiting_on << snapshot.reset_7d if weekly_spent
    return nil unless waiting_on.all? { |reset_time| pending?(reset_time) }

    waiting_on.max
  end

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
