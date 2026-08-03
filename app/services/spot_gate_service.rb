# frozen_string_literal: true

# Decides whether a spot session may start right now.
#
# == The rule
#
# A spot session starts while BOTH windows are forecast to stay under their
# configured ceiling:
#
#     forecast = utilization now + (rate × sessions running × hours left in window)
#
# `utilization now` comes from the pool's live snapshots. `rate` is
# ClaudeUsageRateService's per-session-hour figure. `hours left` is the time to
# the window's own reset. So the forecast answers: if the current fleet keeps
# running at the current burn, where does this window land by the time it resets?
#
# Priority sessions are never consulted about any of this. They start.
#
# == "Hold" means DEFER, not refuse
#
# A held session is not rejected and nothing is lost. It stays `waiting` — the
# status Zimmer already uses for "created, not started" — and AgentSessionJob
# re-enqueues itself with a delay to re-check. When headroom returns, or simply
# when the 5-hour window resets, the same job starts the session normally.
#
# Refusing instead would mean the gate silently deletes work: a github_issue
# trigger that fires once during a busy afternoon would never run at all, and
# nothing in the UI would say why. Deferral costs a row in `waiting` and buys
# back the entire premise of the feature — spot work is work you are happy to
# have later, not work you are happy to lose.
#
# == Fail-open
#
# Every uncertain condition allows the session: gating off, no rate signal yet,
# no quota snapshots, an unreadable AppSetting. A monitoring gap must not become
# an outage of all automated work. `#reason` names which case applied so the UI
# and MCP can say so rather than showing a bare "allowed".
class SpotGateService
  # How long a held session waits before re-checking. Short enough that headroom
  # returning is noticed promptly; long enough that a held fleet is not
  # re-evaluating every few seconds.
  RETRY_DELAY = 10.minutes

  # Forecast horizon ceiling. A 7-day window can have six days left, and
  # multiplying a per-hour rate out that far produces a number with no
  # predictive content — it says "if nothing ever changes for six days", which
  # nothing ever does. Cap the horizon so the weekly forecast stays a statement
  # about the near future.
  MAX_HORIZON = 24.hours

  Forecast = Data.define(:current, :projected, :threshold, :hours_remaining, :breached) do
    def breached? = breached
    def current_pct = current ? current * 100 : nil
    def projected_pct = projected ? projected * 100 : nil
    def threshold_pct = threshold ? threshold * 100 : nil

    def to_h
      {
        current_pct: current_pct,
        projected_pct: projected_pct,
        threshold_pct: threshold_pct,
        hours_remaining: hours_remaining,
        breached: breached?
      }
    end
  end

  Decision = Data.define(:allowed, :reason, :detail, :forecast_5h, :forecast_7d, :rate, :active_sessions) do
    def allowed? = allowed
    def held? = !allowed

    def to_h
      {
        allowed: allowed?,
        reason: reason,
        detail: detail,
        active_sessions: active_sessions,
        forecast_5h: forecast_5h&.to_h,
        forecast_7d: forecast_7d&.to_h,
        usage_rate: rate&.to_h
      }
    end
  end

  class << self
    # Whether `session` may start now. Priority sessions short-circuit without
    # touching the database beyond their own genesis.
    def allow_start?(session)
      return true unless session.spot?

      evaluate.allowed?
    end

    def evaluate(now: Time.current)
      new(now: now).evaluate
    end
  end

  def initialize(now: Time.current)
    @now = now
  end

  def evaluate
    setting = AppSetting.current

    unless setting.spot_gating_enabled
      return allow("gating_disabled", "Spot gating is turned off — spot sessions start like any other.")
    end

    rate = ClaudeUsageRateService.call(now: @now)
    unless rate.sufficient?
      return allow(
        "insufficient_data",
        "Not enough quota samples yet to forecast (#{rate.sample_count} usable " \
        "#{'sample'.pluralize(rate.sample_count)} in the last #{(rate.lookback / 3600).round}h). " \
        "Spot sessions run until the rate is measurable.",
        rate: rate
      )
    end

    snapshot = pool_snapshot
    unless snapshot
      return allow("no_snapshot", "No Claude Code quota reading available to forecast from.", rate: rate)
    end

    sessions = ClaudeUsageRateService.active_session_count

    five_hour = forecast(
      current: ClaudeAccountQuotaSnapshot.effective_utilization(snapshot.utilization_5h, snapshot.reset_5h),
      reset_at: snapshot.reset_5h,
      rate: rate.rate_5h,
      sessions: sessions,
      threshold_pct: setting.spot_gate_five_hour_threshold_pct
    )
    weekly = forecast(
      current: ClaudeAccountQuotaSnapshot.effective_utilization(snapshot.utilization_7d, snapshot.reset_7d),
      reset_at: snapshot.reset_7d,
      rate: rate.rate_7d,
      sessions: sessions,
      threshold_pct: setting.spot_gate_weekly_threshold_pct
    )

    breaches = []
    breaches << "5-hour window forecast at #{five_hour.projected_pct.round}% (limit #{five_hour.threshold_pct.round}%)" if five_hour&.breached?
    breaches << "weekly window forecast at #{weekly.projected_pct.round}% (limit #{weekly.threshold_pct.round}%)" if weekly&.breached?

    if breaches.any?
      Decision.new(
        allowed: false,
        reason: "forecast_breached",
        detail: "Holding spot sessions: #{breaches.join(' and ')}. Priority sessions are unaffected.",
        forecast_5h: five_hour, forecast_7d: weekly, rate: rate, active_sessions: sessions
      )
    else
      Decision.new(
        allowed: true,
        reason: "within_forecast",
        detail: "Forecast headroom available in both windows.",
        forecast_5h: five_hour, forecast_7d: weekly, rate: rate, active_sessions: sessions
      )
    end
  rescue ActiveRecord::StatementInvalid, ActiveRecord::NoDatabaseError => e
    allow("unavailable", "Could not evaluate the spot gate (#{e.class}); allowing the session.")
  end

  private

  def allow(reason, detail, rate: nil)
    Decision.new(
      allowed: true, reason: reason, detail: detail,
      forecast_5h: nil, forecast_7d: nil, rate: rate,
      active_sessions: ClaudeUsageRateService.active_session_count
    )
  end

  # The reading the forecast is built from: the latest snapshot of the account
  # that is serving. The gate asks "will the account we are about to spend
  # against run out", so the serving account's own numbers are the right ones —
  # a pool average would hide an exhausted current account behind a fresh spare.
  def pool_snapshot
    scope = ClaudeAccount.for_runtime("claude_code")
    account = scope.find_by(is_current: true) || scope.available.first
    account&.latest_snapshot
  end

  def forecast(current:, reset_at:, rate:, sessions:, threshold_pct:)
    return nil if current.nil?

    threshold = threshold_pct.to_f / 100.0
    hours = horizon_hours(reset_at)
    projected = current + ((rate || 0.0) * sessions * hours)

    Forecast.new(
      current: current,
      projected: projected,
      threshold: threshold,
      hours_remaining: hours,
      breached: projected > threshold
    )
  end

  def horizon_hours(reset_at)
    return MAX_HORIZON / 3600.0 if reset_at.nil?

    hours = (reset_at - @now) / 3600.0
    return 0.0 if hours.negative?

    [ hours, MAX_HORIZON / 3600.0 ].min
  end
end
