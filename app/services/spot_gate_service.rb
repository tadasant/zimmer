# frozen_string_literal: true

# Decides whether a spot session may start right now.
#
# == The rule
#
# A spot session starts while all three hold:
#
#   1. **Every window's non-reserved capacity has room for it.** Not "is
#      utilization under a target" — "would the money this session is about to
#      spend take the window past the part of it spot work is allowed to touch".
#      QuotaCapacityModel holds that arithmetic; the reserve is the part of the
#      window kept back for priority sessions, and everything above it is meant
#      to be consumed rather than left on the table.
#   2. **The fleet's burn rate is inside the pacing curve.** The remaining spot
#      budget divided by the time left in the window is the rate that reaches
#      100% utilization exactly as the window rolls over. Running faster than
#      that is what holds a session — not a percentage cliff.
#   3. **The fleet has a free slot.** `spot_max_concurrent_sessions` (set on
#      /inference) caps how many sessions run at once.
#
# Priority sessions are never consulted about any of this. They start.
#
# == Why this replaced the percentage targets
#
# The gate used to compare pooled utilization against a target percentage: under
# it, spot work ran flat out; at it, everything stopped. That has three problems
# the dollar model fixes.
#
# A percentage says nothing about **how much capacity is left**. "76% of a 65%
# target" cannot be compared to "keep $200 back for priority work", so a reserve
# could not be expressed at all.
#
# A hard target **wastes capacity**. Under the line the gate admitted everything
# it could, and the fleet burned through the allowance early; at the line
# everything slammed to a halt for hours. On 2026-08-23 that was 21 spot sessions
# paused mid-run against a 5-hour window sitting at 76% of its 65% target — a
# backlog stalled at a cliff rather than paced into the room that was left.
#
# And a hard target **bursts and then idles**. What is wanted is some work
# happening at all hours, which is what a rate-based curve produces and a level
# comparison cannot.
#
# == The curve is self-correcting, and it always leaves room for one session
#
# Because the sustainable rate is "what is LEFT over the time left to spend it",
# a quiet window releases work faster and a busy one throttles — no cliff at
# either end. And because a session is not infinitely divisible, the pace
# condition is waived when nothing at all is running, so a deployment whose
# single-session burn rate exceeds its sustainable rate still does work in a duty
# cycle instead of doing none. QuotaCapacityModel documents both.
#
# == The cap counts everything, and holds only spot
#
# Every running Claude Code session counts against the concurrency cap and
# against the projected burn, priority included, but only spot sessions are held.
# Priority work crowds spot work out of the slots and out of the budget, which is
# the intent: that is what the reserve is protecting.
#
# == The pool decides, not one account
#
# Utilization is read across the whole pool — `ClaudeAccountPool`, the same
# average /inference renders — and so is the time left in each window. One account
# at its cap does not stop the fleet while the rest has room.
#
# **Every account counts, whatever its status.** A needs_reauth account is one
# Zimmer cannot serve from right now, not one whose quota is spent: its windows
# keep draining while it waits for a human. The average carries one correction,
# the page's: an account whose 7-day window is spent counts as 100% in the
# 5-hour figure, because its 5-hour headroom cannot be served.
#
# == "Hold" means DEFER, not refuse
#
# A held session stays `waiting` and AgentSessionJob re-enqueues itself to
# re-check. Nothing is cancelled and no prompt is lost — see SpotSessionHold.
#
# == The budget is a ceiling, not just a starting line
#
# Admission is only half of it. A session admitted with room to spare goes on
# spending, so SpotSessionPause re-evaluates the same decision for the sessions
# already RUNNING and pauses them when the fleet runs past what the window can
# carry. This service stays the only place that decides.
#
# == Fail-open
#
# Every uncertain condition allows the session: gating off, no quota readings, an
# unreadable AppSetting. A monitoring gap must not become an outage of all
# automated work. `#reason` names which case applied.
class SpotGateService
  # How long a held session waits before re-checking. Short enough that freed
  # capacity is noticed promptly; long enough that a held fleet is not
  # re-evaluating every few seconds. It is also the horizon the cap projects
  # over — QuotaCapacityModel::LOOKAHEAD — because a decision has to hold until
  # the next one.
  RETRY_DELAY = 10.minutes

  # How far below the pacing curve the fleet has to fall before a session that
  # was PAUSED mid-flight is resumed, in percentage points of the window.
  #
  # Admission needs no such margin: holding a session that has not started costs
  # nothing. Resuming one that was interrupted mid-turn costs a lost tool call
  # and a re-orientation prompt, and a session resumed the instant the fleet dips
  # under the curve pushes it straight back over — a pause/resume flap that
  # spends tokens on nothing but flapping. Only .resume_decision applies it, and
  # it is applied as extra reserve rather than as a lowered target, so the money
  # it protects is the same money the reserve protects.
  RESUME_MARGIN_PCT = 5

  # The one hold reason that describes a window, rather than the fleet. Named
  # here and read by SpotSessionHold (which backs off differently for it) and
  # SpotSessionPause (which pauses running sessions for it). It kept its old
  # spelling through the move to dollars on purpose: production sessions carry
  # it in their metadata right now, and renaming a string that is already
  # persisted would make the banners on those sessions unreadable.
  UTILIZATION_REASON = "at_utilization_limit"

  # Every session slot is taken. Named for the same reason as above: surfaces
  # branch on it, and a bare string in three files drifts.
  FLEET_CAP_REASON = "fleet_at_cap"

  # THREE things hold spot work, and they behave differently enough that a
  # surface which does not name which one is holding is telling the reader very
  # little. `Decision#ceiling` answers with one of these.
  #
  #   :fleet_cap    — every session slot is taken. Nothing to do with quota.
  #                   Clears when a running session finishes.
  #   :spot_budget  — a window's non-reserved budget is spent. The ONLY one that
  #                   also pauses spot sessions already running
  #                   (Reading#stops_running_work?), and the only one a clock
  #                   fixes: the money comes back when the window rolls over.
  #   :pacing_curve — the budget still has room, but the fleet is spending it
  #                   faster than the window can carry from here. Running work is
  #                   never interrupted for this. It clears when the fleet's burn
  #                   falls, which waiting alone does not do — see
  #                   Decision#resume_outlook.
  #
  # `:spot_budget` and `:pacing_curve` share `UTILIZATION_REASON` on the wire,
  # because that string is persisted on sessions and cannot be split without
  # breaking the banners on the ones already carrying it. So the distinction is
  # derived here rather than encoded in the reason.
  CEILINGS = %i[fleet_cap spot_budget pacing_curve].freeze

  # One quota window's capacity model, plus what this decision made of it.
  # Wraps QuotaCapacityModel::Window so a Decision is a value that can be
  # rendered without re-reading the database.
  Reading = Data.define(:window, :burn_units_per_minute, :within_cap, :within_pace, :pace_waived) do
    def label = window.label
    def dollars? = window.dollars?

    # True when this window refuses to ADMIT a session. A waived pace (nothing is
    # running, see QuotaCapacityModel) leaves only the cap.
    def at_limit? = !within_cap || (!pace_waived && !within_pace)

    # True when this window refuses to let work that is ALREADY RUNNING continue.
    #
    # Only the cap, never the pace. The cap protects the priority reserve, which
    # is a hard invariant worth interrupting a turn for. The pace is an
    # ADMISSION device — it decides how fast new work is released — and killing a
    # running turn to enforce a curve costs a lost tool call while protecting
    # nothing: the same money is spent either way, just later.
    #
    # Keeping them apart is also what makes the idle-fleet waiver coherent. The
    # waiver admits one session precisely when the sustainable rate is below a
    # single session's burn; if the ceiling sweep then paused it for being ahead
    # of the curve, the pair would flap — admit, pause, resume, admit — and the
    # duty cycle the waiver exists to produce would never happen.
    def stops_running_work? = !within_cap

    # The pool's utilization of this window, as a fraction and as a percentage.
    def current = window.utilization
    def current_pct = window.utilization * 100

    # Where the pacing curve says the window should be by now, as a percentage
    # of the window. This is what replaced the flat target: it moves with the
    # clock instead of sitting still.
    # The burn this reading was tested against, or nil when no rate could be
    # read at all. Nil is not zero: "we cannot price the fleet" and "the fleet
    # costs nothing" are opposite claims, and only one of them is ever true.
    def burn_known? = !burn_units_per_minute.nil?

    def pace_pct
      elapsed = window.elapsed_fraction
      return nil if elapsed.nil?

      (window.spot_budget_units / window.capacity_units) * elapsed * 100
    end

    # The share of the window spot work is allowed to consume in total, as a
    # percentage — the complement of the reserve.
    def spot_budget_pct = (window.spot_budget_units / window.capacity_units) * 100

    def why_held
      return "spot budget spent" unless within_cap

      "running ahead of the pacing curve"
    end

    def to_h
      window.to_h.merge(
        at_limit: at_limit?,
        within_cap: within_cap,
        within_pace: within_pace,
        pace_waived: pace_waived,
        pace_pct: pace_pct,
        spot_budget_pct: spot_budget_pct,
        projected_burn_usd_per_minute: dollars? ? burn_units_per_minute : nil
      )
    end
  end

  # When the ACCOUNT POOL regains capacity, carried off ClaudeAccountPool::Measure
  # so every surface answers "how long is this down for" from one computation.
  #
  # A different question from Decision#resume_outlook, which is about this gate's
  # own ceilings. This one is about Claude's quota: the pool can be out of
  # capacity while the gate is wide open, and the gate can hold spot work on a
  # pacing curve while every account has room.
  #
  # Both timestamps are nil for two different reasons, and a caller cannot act on
  # "nil" without knowing which — so the two counts that tell them apart travel
  # with them, exactly as they do on the /inference banner:
  #
  # - `next_capacity_at` is nil because the pool has capacity NOW (`capacity_now`
  #   is true, and there is nothing to wait for) or because everything is blocked
  #   with no reset time recorded (`capacity_now` is false, and nothing knows when
  #   the pool comes back).
  # - `next_weekly_reset` is nil because no account's week is spent
  #   (`weekly_spent_count` is zero, so a 7-day rollover is not what holds the
  #   pool) or because the accounts whose week IS spent recorded no reset time.
  #
  # `read_count` and `servable_count` are the same two figures the banner names
  # its accounts with, so a surface reading this can say "3 accounts of 5" rather
  # than "at least one". Both are copies, and there is no `blocked_count` because
  # nothing needs one: the blocked sentences only render when `capacity_now` is
  # false, which is exactly when every account with a reading is blocked.
  PoolCapacity = Data.define(:next_capacity_at, :next_weekly_reset,
                             :capacity_now, :weekly_spent_count,
                             :read_count, :servable_count) do
    # Copied off the measure rather than derived here. A second derivation is the
    # drift this type exists to prevent, so every field is a straight read —
    # including the two that Measure itself derives.
    #
    # Nil when the pool has nothing to say, which is the same guard
    # `pool_capacity_banner` applies before rendering anything: a measure over
    # zero readings would report "nobody has capacity and nobody knows when",
    # which is a claim about a pool that was never probed.
    def self.from(measure)
      return nil unless measure.any_readings?

      new(next_capacity_at: measure.next_capacity_at, next_weekly_reset: measure.next_weekly_reset,
          capacity_now: measure.capacity_now?, weekly_spent_count: measure.weekly_spent_count,
          read_count: measure.read_count, servable_count: measure.servable_count)
    end

    # Data's own to_h is exactly these fields, so there is nothing to override —
    # unlike Reading and Decision below, which serialize derived figures too.
    def capacity_now? = capacity_now
  end

  # Both windows as this decision read them, how the average was taken, and when
  # the pool underneath them comes back.
  PoolReading = Data.define(:five_hour, :weekly, :account_count, :read_count, :capacity) do
    # Window label => reading, skipping a window with no usable number. Labelled
    # rather than positional because two windows can hold equal values and Data
    # compares by value — telling them apart by identity would occasionally name
    # the wrong one as the reason a session was held.
    def labelled = { "5-hour" => five_hour, "weekly" => weekly }.compact

    def at_limit = labelled.select { |_label, reading| reading.at_limit? }

    def at_limit? = at_limit.any?

    # The windows that refuse to let RUNNING work continue — see
    # Reading#stops_running_work?.
    def stops_running_work = labelled.select { |_label, reading| reading.stops_running_work? }

    # How the average was taken, for the sentence that reports it. Says "3 of 4"
    # only when they differ, because an account with no reading at all is the
    # case worth naming — the pool figure is quietly over a smaller set.
    def accounts_phrase
      counted = read_count == account_count ? "all #{account_count}" : "#{read_count} of #{account_count}"
      "averaged across #{counted} #{'account'.pluralize(account_count)}"
    end
  end

  Decision = Data.define(:allowed, :reason, :detail, :five_hour, :weekly,
                         :active_sessions, :awaiting_sessions, :fleet_cap, :accounts_read, :pool_size,
                         :fleet_burn_usd_per_minute, :candidate_burn_usd_per_minute,
                         :pool_capacity) do
    def allowed? = allowed
    def held? = !allowed

    # Whether this decision is one that should stop work ALREADY RUNNING, as
    # opposed to one that merely declines to start more. Only a spent budget
    # qualifies — see Reading#stops_running_work?. SpotSessionPause reads this
    # rather than `held?`, so a fleet that is merely ahead of the pacing curve is
    # throttled at the door instead of interrupted mid-turn.
    def stops_running_work?
      return false unless reason == UTILIZATION_REASON

      [ five_hour, weekly ].compact.any?(&:stops_running_work?)
    end

    # What the whole fleet plus one more session is projected to burn, in $/min.
    # Nil when no burn rate could be read at all.
    def projected_burn_usd_per_minute
      return nil if fleet_burn_usd_per_minute.nil? && candidate_burn_usd_per_minute.nil?

      fleet_burn_usd_per_minute.to_f + candidate_burn_usd_per_minute.to_f
    end

    # Which of the three CEILINGS is holding spot work, or nil when none is.
    def ceiling
      return nil if allowed?
      return :fleet_cap if reason == FLEET_CAP_REASON
      return nil unless reason == UTILIZATION_REASON

      stops_running_work? ? :spot_budget : :pacing_curve
    end

    # The windows that refused, labelled. Empty unless a window is what refused.
    def held_windows
      return {} unless reason == UTILIZATION_REASON

      { "5-hour" => five_hour, "weekly" => weekly }.compact.select { |_label, r| r.at_limit? }
    end

    # The subset of those whose non-reserved budget is actually SPENT, as opposed
    # to merely being outrun.
    #
    # The two are not the same set, and conflating them puts a false sentence on
    # the page: with the 5-hour budget spent and the weekly window only ahead of
    # its curve, `ceiling` is `:spot_budget` while `held_windows` still names both
    # — so copy built from `held_windows` would say the weekly budget is spent
    # when it has money left. It also decides the rollover: a pace-held window can
    # clear the moment the fleet slows, so including it in a "no sooner than"
    # bound over-claims.
    def budget_spent_windows
      held_windows.select { |_label, r| r.stops_running_work? }
    end

    # The latest rollover among `windows`, or nil when any of them has no
    # rollover time to read. The LATEST, because every window has to clear before
    # spot work runs again, so the last one is the binding constraint.
    def latest_rollover(windows)
      seconds = windows.each_value.map { |r| r.window.seconds_remaining }
      return nil if seconds.empty? || seconds.any?(&:nil?)

      seconds.max
    end

    # The burn rate the fleet has to fall below before the pacing curve releases
    # spot work: the tightest sustainable rate among the windows now holding it.
    # Nil when no window holding this decision is denominated in dollars, or when
    # none has a rollover time to divide by.
    def sustainable_usd_per_minute
      rates = held_windows.each_value.select(&:dollars?)
        .filter_map { |r| r.window.sustainable_units_per_minute }
        .reject(&:infinite?)

      rates.min
    end

    # When the hold lifts on its own, as far as the model can honestly say.
    #
    # Returns `[kind, seconds]`, where `seconds` is a rollover time and may be
    # nil. There is no fourth answer that is a real ETA, and this is the point:
    #
    #   :fleet_cap     — a slot frees when a session ends. Nothing predicts that.
    #   :spot_budget   — the money is gone. Only a rollover puts it back, so the
    #                    rollover IS the answer, and it is a lower bound: the pool
    #                    average has to actually fall, and any window that is
    #                    merely ahead of its curve has to come back too.
    #   :burn_must_fall — the pacing case, and the one worth being blunt about.
    #                    The sustainable rate is what is LEFT over the time LEFT.
    #                    While the fleet outruns it the numerator falls faster
    #                    than the denominator, so the rate keeps dropping and
    #                    waiting makes the gap WIDER, never narrower. The hold
    #                    lifts when the fleet's burn falls — running sessions
    #                    ending is what does that — or when the window rolls over
    #                    and refills the budget. So the seconds here are an upper
    #                    bound on the wait, not a forecast of it.
    #
    # Each kind draws its rollover from the windows that kind is actually about —
    # see #budget_spent_windows for why the two sets differ.
    def resume_outlook
      case ceiling
      when :fleet_cap then [ :fleet_cap, nil ]
      when :spot_budget then [ :spot_budget, latest_rollover(budget_spent_windows) ]
      when :pacing_curve then [ :burn_must_fall, latest_rollover(held_windows) ]
      else [ nil, nil ]
      end
    end

    def to_h
      {
        allowed: allowed?,
        reason: reason,
        ceiling: ceiling,
        detail: detail,
        active_sessions: active_sessions,
        awaiting_sessions: awaiting_sessions,
        fleet_cap: fleet_cap,
        accounts_read: accounts_read,
        pool_size: pool_size,
        fleet_burn_usd_per_minute: fleet_burn_usd_per_minute,
        candidate_burn_usd_per_minute: candidate_burn_usd_per_minute,
        five_hour: five_hour&.to_h,
        weekly: weekly&.to_h,
        pool_capacity: pool_capacity&.to_h
      }
    end
  end

  # The answer for a priority session: it starts, and nothing about quota was
  # consulted to decide that.
  ALWAYS_ALLOWED = Decision.new(
    allowed: true, reason: "priority",
    detail: "Priority sessions are never gated on quota or on the fleet cap.",
    five_hour: nil, weekly: nil, active_sessions: nil, awaiting_sessions: nil, fleet_cap: nil,
    accounts_read: nil, pool_size: nil,
    fleet_burn_usd_per_minute: nil, candidate_burn_usd_per_minute: nil,
    pool_capacity: nil
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

      evaluate(candidate: session)
    end

    # The decision about the fleet AS IT STANDS, with no extra session projected.
    #
    # SpotSessionPause asks a different question from every other caller: not
    # "does one more fit" but "is what is already running over the line". Adding
    # a hypothetical session's burn to that projection would pause running work
    # roughly one session's burn early on every sweep.
    def fleet_decision
      new(candidate: :none).evaluate
    end

    # The decision, for a candidate session and for every surface that reports on
    # the gate. There is exactly one — /inference, `get_spot_policy` and
    # `start_decision` all come through here — so the page, the tool and the
    # production path cannot answer the same question differently.
    #
    # With no candidate the burn of a hypothetical session is the fleet default,
    # which is what "a spot session starting right now would be…" means.
    def evaluate(candidate: nil)
      new(candidate: candidate).evaluate
    end

    # The decision for a session that is already RUNNING and paused: the same
    # evaluation, with RESUME_MARGIN_PCT held back on top of the reserve.
    #
    # Deliberately not rendered anywhere. Its `detail` names the widened reserve,
    # which is the honest description of what it decided on and the wrong number
    # to show beside the policy the operator set.
    def resume_decision
      new(margin_pct: RESUME_MARGIN_PCT).evaluate
    end
  end

  # @param margin_pct [Numeric] percentage points of the window to hold back on
  #   top of the reserve. Zero for every admission decision.
  # @param candidate [Session, nil] the session being admitted, whose own burn
  #   rate is projected. Nil means "some spot session", priced at the fleet
  #   default.
  # @param margin_pct [Numeric] percentage points of the window to hold back on
  #   top of the reserve. Zero for every admission decision.
  # @param candidate [Session, :none, nil] the session being admitted, whose own
  #   burn rate is projected. Nil means "some spot session", priced at the fleet
  #   default; `:none` projects no extra session at all, which is what asking
  #   about the running fleet means.
  def initialize(margin_pct: 0, candidate: nil)
    @margin_pct = margin_pct
    @candidate = candidate
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

  # The fleet cap's population, read once per decision.
  #
  # RunningTurns::Reading rather than a bare count: `running` holds both turns a
  # worker is executing and turns queued behind the `agents` pool waiting for
  # one, and the gate's own explanation has to be able to say which — "15 of 10
  # slots taken" on a deployment with 8 live agent processes reads as a broken
  # counter, which is exactly how #957 was reported. The CAP still compares
  # against the total: a queued turn is committed demand that takes the next free
  # worker, so admitting more spot work on the strength of it only deepens the
  # queue.
  def turns = @turns ||= Session.running_claude_code_turns

  def active_sessions = turns.total

  def awaiting_sessions = turns.awaiting_a_worker

  # What every Claude Code session running right now is burning, in $/min.
  #
  # Every running session counts, priority included: they spend against the same
  # windows, and a fleet of priority work is exactly the case the reserve exists
  # for. A session whose harness+model combination has never been sampled is
  # priced at the fleet default rather than at nothing, so an unknown combination
  # cannot look free.
  def fleet_burn_usd_per_minute
    return @fleet_burn if defined?(@fleet_burn)

    @fleet_burn = begin
      rates = HarnessModelBurnRate.table
      default = HarnessModelBurnRate.fleet_default_usd_per_minute
      return @fleet_burn = nil if rates.empty? && default.nil?

      Session.running_claude_code_burn_keys.sum { |key| rates[key] || default.to_f }
    end
  end

  # What the session being admitted is expected to burn. The fleet default when
  # it is a hypothetical one, or when its own combination has never been sampled.
  def candidate_burn_usd_per_minute
    return @candidate_burn if defined?(@candidate_burn)

    return @candidate_burn = 0.0 if @candidate == :none

    default = HarnessModelBurnRate.fleet_default_usd_per_minute
    @candidate_burn = if @candidate.nil?
      default
    else
      key = [ @candidate.metadata&.dig("agent_root_key").to_s, @candidate.config&.dig("model").to_s ]
      HarnessModelBurnRate.table[key] || default
    end
  end

  # The total burn a window's cap and pacing curve are tested against: the fleet
  # as it stands, plus the one more session under consideration.
  def projected_burn_usd_per_minute
    return nil if fleet_burn_usd_per_minute.nil? && candidate_burn_usd_per_minute.nil?

    fleet_burn_usd_per_minute.to_f + candidate_burn_usd_per_minute.to_f
  end

  # The one decision built without touching the database. Whatever went wrong may
  # well have been the database itself, so re-reading the fleet count here would
  # raise a second time — inside the rescue, where nothing catches it, and on into
  # AgentSessionJob, which fails the session.
  def unavailable(error)
    Decision.new(
      allowed: true, reason: "unavailable",
      detail: "Could not evaluate the spot gate (#{error.class}); allowing the session.",
      five_hour: nil, weekly: nil,
      active_sessions: @turns&.total, awaiting_sessions: @turns&.awaiting_a_worker,
      fleet_cap: nil, accounts_read: nil, pool_size: nil,
      fleet_burn_usd_per_minute: nil, candidate_burn_usd_per_minute: nil,
      pool_capacity: nil
    )
  end

  def allow(reason, detail)
    Decision.new(
      allowed: true, reason: reason, detail: detail,
      five_hour: nil, weekly: nil,
      active_sessions: active_sessions, awaiting_sessions: awaiting_sessions,
      fleet_cap: nil, accounts_read: nil, pool_size: nil,
      fleet_burn_usd_per_minute: nil, candidate_burn_usd_per_minute: nil,
      pool_capacity: nil
    )
  end

  def allowed(pool, fleet_cap)
    decision(
      allowed: true, reason: "within_limits",
      detail: "#{slots_phrase(fleet_cap)} taken, and #{window_phrase(pool)}, #{pool.accounts_phrase}.",
      pool: pool, fleet_cap: fleet_cap
    )
  end

  # A window has no room for this session — either its non-reserved budget is
  # spent, or the fleet is already running ahead of the curve that fills it.
  def at_limit(pool, fleet_cap)
    reached = pool.at_limit.map { |label, reading| "#{label} window #{limit_phrase(reading)}" }

    decision(
      allowed: false, reason: UTILIZATION_REASON,
      detail: "Holding spot sessions: #{reached.join(' and ')}, #{pool.accounts_phrase}. " \
              "Spot work resumes as the window's pacing curve catches up. Priority sessions are unaffected.",
      pool: pool, fleet_cap: fleet_cap
    )
  end

  # Every slot is taken. Priority sessions occupy slots and are never held by
  # this — a fleet of priority work crowding spot work out is the intent.
  def at_fleet_cap(pool, fleet_cap)
    decision(
      allowed: false, reason: FLEET_CAP_REASON,
      detail: "Holding spot sessions: #{slots_phrase(fleet_cap)} taken#{awaiting_clause}. Every session " \
              "with a turn in flight counts, priority included — priority work is meant to crowd spot " \
              "work out. Raise the limit on /inference to widen it.",
      pool: pool, fleet_cap: fleet_cap
    )
  end

  def decision(allowed:, reason:, detail:, pool:, fleet_cap:)
    Decision.new(
      allowed: allowed, reason: reason, detail: detail.squish,
      five_hour: pool.five_hour, weekly: pool.weekly,
      active_sessions: active_sessions, awaiting_sessions: awaiting_sessions, fleet_cap: fleet_cap,
      accounts_read: pool.read_count, pool_size: pool.account_count,
      fleet_burn_usd_per_minute: fleet_burn_usd_per_minute,
      candidate_burn_usd_per_minute: candidate_burn_usd_per_minute,
      pool_capacity: pool.capacity
    )
  end

  def slots_phrase(fleet_cap)
    "#{active_sessions} of #{fleet_cap} session #{'slot'.pluralize(fleet_cap)}"
  end

  # Where the slot count came from, when it is not simply "that many agents are
  # running". Silent when no turn is waiting, because then the two are the same
  # number and the clause is noise.
  #
  # "Waiting for one" rather than "queued": the population is every counted row
  # no worker has started, which is turns in the `agents` lane plus rows between
  # jobs. See RunningTurns::Reading.
  def awaiting_clause
    return "" unless awaiting_sessions.positive?

    " (#{turns.on_a_worker} on a worker, #{awaiting_sessions} waiting for one behind the " \
      "#{RunningTurns.worker_slots}-slot agents pool)"
  end

  # Why one window refused, in money when the model has money and in percentages
  # of the window when it does not.
  def limit_phrase(reading)
    window = reading.window
    return "has spent $#{money(window.spent_units)} of its $#{money(window.spot_budget_usd)} spot budget" if !reading.within_cap && window.dollars?
    return "is at #{reading.current_pct.round}% of the #{reading.spot_budget_pct.round}% spot budget" unless reading.within_cap

    pace = reading.pace_pct
    rate = window.sustainable_units_per_minute
    if window.dollars? && rate && reading.burn_known?
      "is burning $#{money(reading.burn_units_per_minute)}/min against $#{money(rate)}/min sustainable"
    else
      "is at #{reading.current_pct.round}% against a pacing curve at #{pace&.round}%"
    end
  end

  def window_phrase(pool)
    pool.labelled.map do |label, reading|
      window = reading.window
      if window.dollars?
        "#{label} has $#{money(window.remaining_spot_units)} of spot budget left"
      else
        "#{label} at #{reading.current_pct.round}% of its #{reading.spot_budget_pct.round}% spot budget"
      end
    end.join(", ")
  end

  # Delimited, because these figures land in a sentence a human reads on the
  # /inference card and in `get_spot_policy`: "$2437.62" is a number to decode and
  # "$2,437.62" is one to read.
  def money(value)
    return "—" if value.nil?
    return "∞" if value.infinite?

    ActiveSupport::NumberHelper.number_to_delimited(format("%.2f", value))
  end

  # Both windows as the pool is carrying them, wrapped in the capacity model and
  # tested against the burn this decision projects. A pool where nothing has been
  # read, or where neither window can be read, leaves nothing to decide on and
  # the gate falls open.
  def pool_reading(setting)
    measure = ClaudeAccountPool.measure
    return nil unless measure.any_readings?

    windows = QuotaCapacityModel.windows(measure: measure, setting: setting, margin_pct: @margin_pct)
    return nil if windows.empty?

    burn = projected_burn_usd_per_minute
    # A session is not infinitely divisible: with nothing running at all, the
    # pacing curve is waived so the deployment still does SOME work whatever its
    # sustainable rate. The cap is not waived — the reserve is protected either
    # way. See QuotaCapacityModel.
    waived = active_sessions.zero?

    PoolReading.new(
      five_hour: reading(windows[QuotaCapacityEstimate::FIVE_HOUR], burn, waived),
      weekly: reading(windows[QuotaCapacityEstimate::WEEKLY], burn, waived),
      account_count: measure.account_count, read_count: measure.read_count,
      capacity: PoolCapacity.from(measure)
    )
  end

  # One window's verdict. The burn is in dollars, so a window with no dollar
  # capacity cannot test it — that window falls back to the cumulative pacing
  # curve on utilization alone, which is the same shape without the projection.
  def reading(window, burn_usd_per_minute, pace_waived)
    return nil if window.nil?

    if window.dollars? && burn_usd_per_minute
      Reading.new(window: window, burn_units_per_minute: burn_usd_per_minute,
                  within_cap: window.within_cap?(burn_usd_per_minute),
                  within_pace: window.within_pace?(burn_usd_per_minute),
                  pace_waived: pace_waived)
    else
      # Fraction mode: no rate to project, so the cap is tested against what has
      # been spent and the pace against where the curve says the window should
      # be by now. Both still reach 100% of the spot budget at rollover.
      elapsed = window.elapsed_fraction
      allowance = elapsed.nil? ? window.spot_budget_units : window.spot_budget_units * elapsed
      # Strictly under, not at. With no rate to project, a window sitting exactly
      # on its budget has nothing left for the session being admitted, and `<=`
      # would wave it through on the strength of capacity it has already spent.
      # Dollar mode needs no such rule: the projection is what makes the
      # comparison strict there.
      Reading.new(window: window, burn_units_per_minute: nil,
                  within_cap: window.spent_units < window.spot_budget_units,
                  within_pace: window.spent_units < allowance,
                  pace_waived: pace_waived)
    end
  end
end
