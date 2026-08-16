# frozen_string_literal: true

# Decides whether a spot session may start right now.
#
# == The rule
#
# Two checks, both against numbers that have already been measured. A spot
# session starts while BOTH hold:
#
#   1. **The serving Claude Code account is under both targets.** Utilization as
#      last read, not a projection of it. Once a window reaches its target, spot
#      work pauses until utilization comes back down — the 5-hour window falls on
#      its own as its sliding window ages events out, and the weekly one behind
#      it.
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
# == The account that will actually serve
#
# Utilization is read from the account Zimmer is serving from, because that is
# the one a session started now will spend against: rotation happens when the
# serving account is REFUSED, not when it reaches a target, so a spare's headroom
# is not headroom this session can use. A spare's reading is also the stalest
# thing in the pool — ClaudeUsageSamplerJob refreshes only the serving account,
# and a spare is read on rotation or a /quotas visit — so deciding on the
# roomiest account would mean deciding on the number least likely to be true.
#
# With no current account, the first available one stands in: that is who would
# serve. `available` is the pool AccountRotationService picks from — active
# status, credentials on file — so an account already marked quota_exceeded is
# skipped rather than read.
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

  # One account's two windows, so the pool can be compared account by account.
  AccountReading = Data.define(:email, :five_hour, :weekly) do
    # Window label => reading, skipping a window with no usable number. Labelled
    # rather than positional because two windows can hold equal values and Data
    # compares by value — telling them apart by identity would occasionally name
    # the wrong one as the reason a session was held.
    def labelled = { "5-hour" => five_hour, "weekly" => weekly }.compact

    def at_limit = labelled.select { |_label, window| window.at_limit? }

    def at_limit? = at_limit.any?
  end

  Decision = Data.define(:allowed, :reason, :detail, :five_hour, :weekly,
                         :active_sessions, :fleet_cap, :account_email) do
    def allowed? = allowed
    def held? = !allowed

    def to_h
      {
        allowed: allowed?,
        reason: reason,
        detail: detail,
        active_sessions: active_sessions,
        fleet_cap: fleet_cap,
        account_email: account_email,
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
    five_hour: nil, weekly: nil, active_sessions: nil, fleet_cap: nil, account_email: nil
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

    account = serving_reading(setting)
    return allow("no_snapshot", "No Claude Code quota reading to decide on.") if account.nil?

    fleet_cap = setting.spot_max_concurrent_sessions

    if account.at_limit?
      at_limit(account, fleet_cap)
    elsif active_sessions >= fleet_cap
      at_fleet_cap(account, fleet_cap)
    else
      allowed(account, fleet_cap)
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
      active_sessions: @active_sessions, fleet_cap: nil, account_email: nil
    )
  end

  def allow(reason, detail)
    Decision.new(
      allowed: true, reason: reason, detail: detail,
      five_hour: nil, weekly: nil,
      active_sessions: active_sessions, fleet_cap: nil, account_email: nil
    )
  end

  def allowed(account, fleet_cap)
    decision(
      allowed: true, reason: "within_limits",
      detail: "#{slots_phrase(fleet_cap)} taken, and #{window_phrase(account)} on #{account.email}.",
      account: account, fleet_cap: fleet_cap
    )
  end

  # A window has reached its target. Spot work pauses until utilization comes
  # back down; nothing is projected and nothing is cancelled.
  def at_limit(account, fleet_cap)
    reached = account.at_limit.map do |label, window|
      "#{label} window at #{window.current_pct.round}% of its #{window.threshold_pct.round}% target"
    end

    decision(
      allowed: false, reason: "at_utilization_limit",
      detail: "Holding spot sessions: #{reached.join(' and ')} on #{account.email}. " \
              "Spot work waits for utilization to come back down. Priority sessions are unaffected.",
      account: account, fleet_cap: fleet_cap
    )
  end

  # Every slot is taken. Priority sessions occupy slots and are never held by
  # this — a fleet of priority work crowding spot work out is the intent.
  def at_fleet_cap(account, fleet_cap)
    decision(
      allowed: false, reason: "fleet_at_cap",
      detail: "Holding spot sessions: #{slots_phrase(fleet_cap)} taken. Every running session " \
              "counts, priority included — priority work is meant to crowd spot work out. Raise the " \
              "limit on /quotas to widen it.",
      account: account, fleet_cap: fleet_cap
    )
  end

  def decision(allowed:, reason:, detail:, account:, fleet_cap:)
    Decision.new(
      allowed: allowed, reason: reason, detail: detail.squish,
      five_hour: account.five_hour, weekly: account.weekly,
      active_sessions: active_sessions, fleet_cap: fleet_cap, account_email: account.email
    )
  end

  def slots_phrase(fleet_cap)
    "#{active_sessions} of #{fleet_cap} session #{'slot'.pluralize(fleet_cap)}"
  end

  def window_phrase(account)
    account.labelled.map do |label, window|
      "#{label} at #{window.current_pct.round}% of its #{window.threshold_pct.round}% target"
    end.join(", ")
  end

  # The account a session started now would spend against: the one marked
  # current, or the first the pool would serve from when none is. An account with
  # no reading, or none whose windows can be read, leaves nothing to decide on and
  # the gate falls open.
  def serving_reading(setting)
    serving_accounts.lazy.filter_map { |account| reading_for(account, setting) }.first
  end

  def serving_accounts
    scope = ClaudeAccount.for_runtime(ClaudeAuthProvider::RUNTIME)
    current = scope.find_by(is_current: true)
    ([ current ].compact + scope.available.to_a).uniq
  end

  def reading_for(account, setting)
    snapshot = account.latest_snapshot
    return nil if snapshot.nil?

    five_hour = reading(snapshot.utilization_5h, snapshot.reset_5h,
                        setting.spot_gate_five_hour_threshold_pct)
    weekly = reading(snapshot.utilization_7d, snapshot.reset_7d,
                     setting.spot_gate_weekly_threshold_pct)
    # Neither window readable is a reading in name only — skip it rather than let
    # an account with nothing to say answer for the deployment.
    return nil if five_hour.nil? && weekly.nil?

    AccountReading.new(email: account.email, five_hour: five_hour, weekly: weekly)
  end

  # A window's utilization as it stands. Past its reset the sliding window has
  # cleared, so `effective_utilization` reads it as zero rather than holding work
  # against a number that no longer applies.
  def reading(utilization, reset_at, threshold_pct)
    current = ClaudeAccountQuotaSnapshot.effective_utilization(utilization, reset_at)
    return nil if current.nil?

    Reading.new(current: current, threshold: threshold_pct.to_f / 100.0)
  end
end
