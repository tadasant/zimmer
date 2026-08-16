# frozen_string_literal: true

# Decides whether a spot session may start right now.
#
# == The rule
#
# Two checks, both against numbers that have already been measured. A spot
# session starts while BOTH hold:
#
#   1. **The account pool is under both targets, in aggregate.** Utilization as
#      last read, averaged across every account, not a projection of it. Once a
#      window reaches its target, spot work pauses until utilization comes back
#      down — the 5-hour window falls on its own as its sliding window ages
#      events out, and the weekly one behind it.
#   2. **The fleet has a free slot.** `spot_max_concurrent_sessions` (10 by
#      default, set on /quotas) caps how many sessions run at once, which is
#      what bounds how fast the quota can be spent.
#
# Nothing is forecast. The targets on /quotas are a level to **reach** — spot
# work fills the fleet up to the cap and runs until a window arrives at its
# target, rather than backing off from a projection of where it might land. A
# deployment sitting idle should be idle because its windows are at 80%.
#
# Priority sessions are never consulted about any of this. They start.
#
# == The cap counts everything, and holds only spot
#
# Every running Claude Code session counts against the cap, priority included,
# but only spot sessions are held by it. Ten running priority sessions therefore
# leave zero spot slots, which is the intent: priority work crowds spot work out
# of the slots rather than queueing behind it.
#
# The count is checked when a session **starts** and never again. A running
# session is not reconsidered when the fleet grows or a window fills; the
# decision point that means something is "should this work begin at all".
#
# == The pool decides, not one account
#
# The targets are read across the whole pool — `ClaudeAccountPool`, the same
# average /quotas renders as "Avg 5-Hour Utilization (effective)". One account
# at its cap therefore does not stop the fleet while the rest of the pool has
# room, which is what a pool is for: rotation moves work off a refused account
# onto the accounts that still have headroom, so the quota the deployment can
# actually spend is the pool's, not whichever account happens to be serving this
# minute.
#
# **Every account counts, whatever its status** — active, quota_exceeded, and
# needs_reauth alike. A needs_reauth account is one Zimmer cannot serve from
# right now, not one whose quota is spent: its windows keep draining while it
# waits for a human, and its headroom is real again the moment they log back in.
# Dropping it would shrink the denominator to the serving accounts and make the
# average jump every time an account fell out of the pool or came back.
#
# The average carries one correction, and it is the page's, not a second rule
# invented here: an account whose 7-day window is spent counts as 100% in the
# 5-hour figure, because its 5-hour headroom cannot be served. That is the whole
# reason the aggregate does not simply hand a dead account's empty 5-hour
# counter back as room to spend.
#
# == "Hold" means DEFER, not refuse
#
# A held session is not rejected and nothing is lost. It stays `waiting` — the
# status Zimmer already uses for "created, not started" — and AgentSessionJob
# re-enqueues itself to re-check. When a slot frees or the window resets, the
# same job starts the session normally.
#
# Refusing instead would mean the gate silently deletes work: a github_issue
# trigger that fires once during a busy afternoon would never run at all, and
# nothing in the UI would say why. Deferral costs a row in `waiting` and buys
# back the entire premise of the feature — spot work is work you are happy to
# have later, not work you are happy to lose.
#
# == Fail-open
#
# Every uncertain condition allows the session: gating off, no quota readings,
# an unreadable AppSetting. A monitoring gap must not become an outage of all
# automated work. `#reason` names which case applied so the UI and MCP can say
# so rather than showing a bare "allowed".
class SpotGateService
  # How long a held session waits before re-checking. Short enough that a freed
  # slot is noticed promptly; long enough that a held fleet is not re-evaluating
  # every few seconds.
  RETRY_DELAY = 10.minutes

  # One quota window as last read, against the target it is filling toward.
  Reading = Data.define(:current, :threshold) do
    def at_limit? = current >= threshold
    def current_pct = current * 100
    def threshold_pct = threshold * 100

    def to_h
      { current_pct: current_pct, threshold_pct: threshold_pct, at_limit: at_limit? }
    end
  end

  # The pool's two windows, averaged across every account, and how many accounts
  # went into that average.
  PoolReading = Data.define(:five_hour, :weekly, :account_count, :read_count) do
    # Window label => reading, skipping a window with no usable number. Labelled
    # rather than positional because two windows can hold equal values and Data
    # compares by value — telling them apart by identity would occasionally name
    # the wrong one as the reason a session was held.
    def labelled = { "5-hour" => five_hour, "weekly" => weekly }.compact

    def at_limit = labelled.select { |_label, window| window.at_limit? }

    def at_limit? = at_limit.any?

    # How the average was taken, for the sentence that reports it. Says "3 of 4"
    # only when they differ, because an account with no reading at all is the
    # case worth naming — the pool figure is quietly over a smaller set.
    def accounts_phrase
      counted = read_count == account_count ? "all #{account_count}" : "#{read_count} of #{account_count}"
      "averaged across #{counted} #{'account'.pluralize(account_count)}"
    end
  end

  Decision = Data.define(:allowed, :reason, :detail, :five_hour, :weekly,
                         :active_sessions, :fleet_cap, :accounts_read, :pool_size) do
    def allowed? = allowed
    def held? = !allowed

    def to_h
      {
        allowed: allowed?,
        reason: reason,
        detail: detail,
        active_sessions: active_sessions,
        fleet_cap: fleet_cap,
        accounts_read: accounts_read,
        pool_size: pool_size,
        five_hour: five_hour&.to_h,
        weekly: weekly&.to_h
      }
    end
  end

  # The answer for a priority session: it starts, and nothing about quota was
  # consulted to decide that.
  ALWAYS_ALLOWED = Decision.new(
    allowed: true, reason: "priority",
    detail: "Priority sessions are never gated on quota or on the fleet cap.",
    five_hour: nil, weekly: nil, active_sessions: nil, fleet_cap: nil,
    accounts_read: nil, pool_size: nil
  ).freeze

  class << self
    # Whether `session` may start now. Priority sessions short-circuit without
    # touching the database beyond their own genesis.
    def allow_start?(session)
      start_decision(session).allowed?
    end

    # The Decision for starting `session`, and the single seam the production
    # path goes through — SpotSessionHold calls this, so `allow_start?` is a read
    # of live behavior rather than a parallel implementation that could drift.
    #
    # A priority session is answered without touching the quota tables at all.
    def start_decision(session)
      return ALWAYS_ALLOWED unless session.spot?

      evaluate
    end

    # The decision, for a spot session and for every surface that reports on it.
    # There is exactly one — /quotas and `get_spot_policy` both render this — so
    # the page and the tool cannot answer the same question differently.
    def evaluate
      new.evaluate
    end
  end

  def evaluate
    setting = AppSetting.current

    unless setting.spot_gating_enabled
      return allow("gating_disabled", "Spot gating is turned off — spot sessions start like any other.")
    end

    pool = pool_reading(setting)
    return allow("no_snapshot", "No Claude Code quota reading to decide on.") if pool.nil?

    fleet_cap = setting.spot_max_concurrent_sessions

    if pool.at_limit?
      at_limit(pool, fleet_cap)
    elsif active_sessions >= fleet_cap
      at_fleet_cap(pool, fleet_cap)
    else
      allowed(pool, fleet_cap)
    end
  # StandardError, deliberately broad. ActiveRecord::ConnectionNotEstablished and
  # its ConnectionTimeoutError subclass descend from AdapterError, NOT from
  # StatementInvalid — and pool exhaustion is very reachable with a fleet of
  # concurrent AgentSessionJobs. Anything narrower lets the exception escape into
  # AgentSessionJob, which marks the session `failed`. A spot session must never
  # be failed by the thing whose entire promise is that it only defers.
  rescue StandardError => e
    Rails.logger.warn("[SpotGateService] Could not evaluate (#{e.class}: #{e.message}); allowing the session")
    unavailable(e)
  end

  private

  def active_sessions = @active_sessions ||= Session.running_claude_code_count

  # The one decision built without touching the database. Whatever went wrong may
  # well have been the database itself, so re-reading the fleet count here would
  # raise a second time — inside the rescue, where nothing catches it, and on into
  # AgentSessionJob, which fails the session.
  def unavailable(error)
    Decision.new(
      allowed: true, reason: "unavailable",
      detail: "Could not evaluate the spot gate (#{error.class}); allowing the session.",
      five_hour: nil, weekly: nil,
      active_sessions: @active_sessions, fleet_cap: nil, accounts_read: nil, pool_size: nil
    )
  end

  def allow(reason, detail)
    Decision.new(
      allowed: true, reason: reason, detail: detail,
      five_hour: nil, weekly: nil,
      active_sessions: active_sessions, fleet_cap: nil, accounts_read: nil, pool_size: nil
    )
  end

  def allowed(pool, fleet_cap)
    decision(
      allowed: true, reason: "within_limits",
      detail: "#{slots_phrase(fleet_cap)} taken, and #{window_phrase(pool)}, #{pool.accounts_phrase}.",
      pool: pool, fleet_cap: fleet_cap
    )
  end

  # A window has reached its target across the pool. Spot work pauses until
  # utilization comes back down; nothing is projected and nothing is cancelled.
  def at_limit(pool, fleet_cap)
    reached = pool.at_limit.map do |label, window|
      "#{label} window at #{window.current_pct.round}% of its #{window.threshold_pct.round}% target"
    end

    decision(
      allowed: false, reason: "at_utilization_limit",
      detail: "Holding spot sessions: #{reached.join(' and ')}, #{pool.accounts_phrase}. " \
              "Spot work waits for utilization to come back down. Priority sessions are unaffected.",
      pool: pool, fleet_cap: fleet_cap
    )
  end

  # Every slot is taken. Priority sessions occupy slots and are never held by
  # this — a fleet of priority work crowding spot work out is the intent.
  def at_fleet_cap(pool, fleet_cap)
    decision(
      allowed: false, reason: "fleet_at_cap",
      detail: "Holding spot sessions: #{slots_phrase(fleet_cap)} taken. Every running session " \
              "counts, priority included — priority work is meant to crowd spot work out. Raise the " \
              "limit on /quotas to widen it.",
      pool: pool, fleet_cap: fleet_cap
    )
  end

  def decision(allowed:, reason:, detail:, pool:, fleet_cap:)
    Decision.new(
      allowed: allowed, reason: reason, detail: detail.squish,
      five_hour: pool.five_hour, weekly: pool.weekly,
      active_sessions: active_sessions, fleet_cap: fleet_cap,
      accounts_read: pool.read_count, pool_size: pool.account_count
    )
  end

  def slots_phrase(fleet_cap)
    "#{active_sessions} of #{fleet_cap} session #{'slot'.pluralize(fleet_cap)}"
  end

  def window_phrase(pool)
    pool.labelled.map do |label, window|
      "#{label} at #{window.current_pct.round}% of its #{window.threshold_pct.round}% target"
    end.join(", ")
  end

  # Both windows as the pool is carrying them. A pool where nothing has been read,
  # or where neither window can be read, leaves nothing to decide on and the gate
  # falls open.
  def pool_reading(setting)
    measure = ClaudeAccountPool.measure
    return nil unless measure.any_readings?

    five_hour = reading(measure.five_hour, setting.spot_gate_five_hour_threshold_pct)
    weekly = reading(measure.weekly, setting.spot_gate_weekly_threshold_pct)
    return nil if five_hour.nil? && weekly.nil?

    PoolReading.new(five_hour: five_hour, weekly: weekly,
                    account_count: measure.account_count, read_count: measure.read_count)
  end

  # A window's pooled utilization against its target. ClaudeAccountPool has
  # already applied the reset rule per account — a window past its reset carries
  # nothing — so what arrives here is the average of numbers that still apply.
  def reading(current, threshold_pct)
    return nil if current.nil?

    Reading.new(current: current, threshold: threshold_pct.to_f / 100.0)
  end
end
