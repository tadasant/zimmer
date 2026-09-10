# frozen_string_literal: true

# What the whole account pool is carrying right now, as one pair of numbers.
#
# There is exactly one of these because two surfaces act on it: the "Account
# Pool" section of /inference renders it, and SpotGateService decides whether spot
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
  # How a reset time is written wherever one is shown. UTC, because the two
  # surfaces that render it disagree about who is reading: /inference rewrites it to
  # the viewer's wall clock in the browser, and `get_spot_policy` answers an agent
  # that has no viewer timezone to be rewritten into. One constant so a change to
  # the format cannot move one surface without the other.
  RESET_TIME_FORMAT = "%b %-d, %H:%M UTC"

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
  # `five_hour_seconds_remaining` and `weekly_seconds_remaining` are how long
  # each window has left before it rolls over, averaged across the accounts that
  # could say. They are the time axis of the pacing curve — QuotaCapacityModel
  # divides the remaining spot budget by them to get the rate that lands on 100%
  # exactly at the rollover.
  #
  # An AVERAGE, to match the utilization figure beside it: accounts reset at
  # different moments, and the pool number those seconds are paced against is
  # itself an average over the same accounts. Only accounts with a reset still
  # ahead of them contribute — a reset in the past describes a window that has
  # already rolled, the same rule `effective_utilization` applies to the counter.
  # Nil when nobody could say, which turns the pacing curve off rather than
  # guessing at a rollover.
  # == The 5-hour figure is over the accounts whose WEEK still has room
  #
  # `five_hour` averages the 5-hour counter across the accounts a request could
  # actually land on — the ones whose 7-day window is not spent — and reads 1.0
  # when none of them is. A weekly-spent account is left OUT of that average
  # rather than counted at 100% in it, which is the correction this used to
  # carry and the cause of tadasant/zimmer#693.
  #
  # Both spellings say "its 5-hour headroom cannot be served", and the second is
  # the one that is true of the number. Substituting 1.0 says something stronger
  # and false: that the account has CONSUMED its 5-hour allowance. The 5-hour
  # pacing curve reads this figure as consumption and compares it against how
  # far the window has elapsed — so a substituted 1.0 becomes a floor of
  # `weekly_spent / read` on a curve that starts every window at zero, and holds
  # spot work for the opening stretch of every 5-hour window no matter how idle
  # the fleet is. Nothing the fleet does can bring that floor down, because it is
  # not about the 5-hour window at all. In production on 2026-09-10 it was 2 of 7
  # accounts, all seven reading 0.0% on their 5-hour counters: a pooled 28.57%
  # against a curve at 25.15%, holding 33 spot sessions on a fleet that had been
  # idle for four days.
  #
  # An unservable account being unservable is not thereby unsaid. It is stated
  # on the axis it is true of: those accounts read 100% on the WEEKLY figure
  # honestly, which is what holds work while the week is spent. Saying it twice
  # is what put it on a window it was not about.
  #
  # `five_hour_uncorrected` is the same counter averaged across EVERY account
  # with a reading, weekly-spent ones included at their raw 5-hour number. Only
  # QuotaCapacityCalibrator reads it: it divides fleet-wide spend by utilization
  # to price a window, so its denominator has to be the whole pool that produced
  # the spend, not the servable part of it. The weekly figure needs no twin of
  # either kind — a spent week reads as 100% there on its own.
  Measure = Data.define(:five_hour, :five_hour_uncorrected, :weekly,
                        :worst_five_hour, :worst_weekly,
                        :account_count, :read_count, :weekly_spent_count,
                        :blocked_count, :next_capacity_at, :next_weekly_reset,
                        :five_hour_seconds_remaining, :weekly_seconds_remaining) do
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
    # readings. Callers that already hold both (the /inference render) build the
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
    now = Time.current
    fives = []
    fives_servable = []
    fives_uncorrected = []
    weeklies = []
    five_hour_remaining = []
    weekly_remaining = []
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
      five_spent = snapshot.five_hour_window_spent?
      weekly_spent = snapshot.seven_day_window_spent?

      weeklies << weekly if weekly
      # `fives` is the whole pool with the old servability substitution still in
      # it, kept for one job only: it is what the 5-hour figure falls back to
      # when NO account's week has room, where it correctly reads 1.0. Every
      # other case reads `fives_servable` — see the class comment.
      fives << five if five
      fives_servable << five if five && !weekly_spent
      raw_five = ClaudeAccountQuotaSnapshot.effective_utilization(snapshot.utilization_5h, snapshot.reset_5h)
      fives_uncorrected << raw_five if raw_five
      five_hour_remaining << (snapshot.reset_5h - now) if pending?(snapshot.reset_5h)
      weekly_remaining << (snapshot.reset_7d - now) if pending?(snapshot.reset_7d)

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
      # The accounts a request could land on, and the whole pool only when there
      # are none — which is the one state in which the old substitution said
      # something true, and says it here without a substitution: every account
      # left in `fives` is weekly-spent, so the fallback is 1.0.
      five_hour: average(fives_servable) || average(fives),
      five_hour_uncorrected: average(fives_uncorrected),
      weekly: average(weeklies),
      # Read as "the worst of the accounts the figure beside it averaged", so it
      # follows `five_hour` onto the same population rather than reporting a
      # 100% nothing can be served from as the worst of a servable set.
      worst_five_hour: fives_servable.max || fives.max, worst_weekly: weeklies.max,
      account_count: @accounts.size, read_count: read_count,
      weekly_spent_count: weekly_spent_count,
      blocked_count: blocked_count,
      next_capacity_at: serving_now ? nil : capacity_times.min,
      next_weekly_reset: weekly_resets.min,
      five_hour_seconds_remaining: average(five_hour_remaining)&.round,
      weekly_seconds_remaining: average(weekly_remaining)&.round
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
