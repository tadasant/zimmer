# frozen_string_literal: true

# How good a Claude Code account is to be serving from, as one number in [0, 1].
#
# The one formula the pool ranks accounts by. AccountRebalanceService reads it
# to decide whether an idle pool should move to a better account, and
# AccountRotationService reads it to reorder `priority` when an account hits a
# quota wall — so the account the reactive path falls through to next is the one
# the proactive path would have picked. Two rules written side by side would
# drift and the two paths would pull the pool in opposite directions.
#
# == The formula
#
#   score = 0.8 × headroom(7d) + 0.2 × headroom(5h)
#
#   headroom(window) = (1 − u) + u × relief
#   relief           = clamp(1 − time_to_reset / horizon, 0, 1)
#
# where `u` is the window's effective utilization (0 once its reset has passed;
# ClaudeAccountQuotaSnapshot.effective_utilization) and the horizon is 24 hours
# for the 7-day window and 5 hours for the 5-hour one.
#
# * **Headroom, not usage.** An account is worth serving from in proportion to
#   how much of its allowance is left. A fresh account scores 1.0, one with both
#   windows spent scores 0.
# * **The 7-day window carries 80% of the weight.** It is the scarce one: it
#   resets once a week, so a point of it spent is gone for days, where a point of
#   the 5-hour window comes back within hours.
# * **Usage that is about to be refunded counts as headroom.** `relief` is the
#   share of the used allowance that the reset will give back soon enough to
#   matter. A 7-day window resetting in six hours gets 75% of its usage back as
#   headroom, so an account at 81% about to reset is worth spending down; one at
#   81% with a day and a half left gets nothing back and ranks well below a fresh
#   account. At the reset itself relief is 1 and the window reads as empty — the
#   same answer effective_utilization gives a moment later, so the score does not
#   jump across the reset. A window with no reset time (Anthropic has not started
#   it yet) gets no relief, and usually has no usage either.
#
# A spent window is not special-cased: utilization at or past the cap is
# headroom 0 on that window. Whether an account can serve at all is #eligible?'s
# question, not this one's — a 5h-spent account still has a meaningful score,
# which is exactly what the priority reshuffle needs to rank it by.
class ClaudeAccountScore
  WEIGHT_7D = 0.8
  WEIGHT_5H = 0.2

  # How far ahead a reset starts to count as headroom.
  RELIEF_HORIZON_7D = 24.hours
  RELIEF_HORIZON_5H = 5.hours

  # How old a reading may be and still decide a proactive switch. Spares are
  # sampled hourly (ClaudeUsageSamplerJob::SPARE_MAX_STALENESS) and the serving
  # account every 15 minutes, so twice the spare cadence tolerates one missed
  # sample without ever switching on a reading from yesterday.
  FRESHNESS = 2.hours

  attr_reader :account, :snapshot, :now

  # Score every account in one pass, loading their latest readings in one query.
  #
  # @return [Hash{Integer => ClaudeAccountScore}] keyed by account id
  def self.for_accounts(accounts, snapshots: nil, now: Time.current)
    snapshots ||= ClaudeAccountPool.latest_snapshots(accounts)
    accounts.to_h { |account| [ account.id, new(account, snapshots[account.id], now: now) ] }
  end

  def initialize(account, snapshot, now: Time.current)
    @account = account
    @snapshot = snapshot
    @now = now
  end

  # The score, or nil when there is no reading to score.
  def value
    return nil if snapshot.nil?

    @value ||= (WEIGHT_7D * headroom(snapshot.utilization_7d, snapshot.reset_7d, RELIEF_HORIZON_7D) +
      WEIGHT_5H * headroom(snapshot.utilization_5h, snapshot.reset_5h, RELIEF_HORIZON_5H)).round(4)
  end

  def fresh?
    snapshot.present? && snapshot.created_at >= now - FRESHNESS
  end

  # Whether a proactive switch may move the pool ONTO this account: it is
  # active, holds a credential Anthropic has not refused, carries a fresh
  # reading, and neither window of that reading is spent. Every condition is a
  # way an account could be handed to the next session and fail it.
  def eligible?
    ineligible_reason.nil?
  end

  # Why #eligible? said no, in words /inference can print, or nil.
  def ineligible_reason
    return "not active (#{account.status.humanize.downcase})" unless account.active?
    return "no stored credential" if account.oauth_config.blank?
    return "credential refused by Anthropic" if account.credential_rejected?
    return "no quota reading yet" if snapshot.nil?
    return "quota reading is older than #{FRESHNESS.inspect}" unless fresh?
    return "7-day window spent" if snapshot.seven_day_window_spent?
    return "5-hour window spent" if snapshot.five_hour_window_spent?

    nil
  end

  private

  def headroom(utilization, reset_at, horizon)
    used = ClaudeAccountQuotaSnapshot.effective_utilization(utilization, reset_at).to_f.clamp(0.0, 1.0)
    (1.0 - used) + used * relief(reset_at, horizon)
  end

  def relief(reset_at, horizon)
    return 0.0 if reset_at.nil?

    (1.0 - (reset_at - now) / horizon.to_f).clamp(0.0, 1.0)
  end
end
