# frozen_string_literal: true

# Moves an idle Claude Code pool onto its best account before anyone needs it.
#
# Reactive rotation (AccountRotationService#rotate!) only ever leaves an account
# once it is exhausted, so the pool can sit on an account at 81% of its week
# while three untouched accounts idle beside it. This is the proactive half: a
# cron sweep (AccountRebalanceJob) that switches the current account to the
# best-scoring one (ClaudeAccountScore) — but only when doing so costs nothing.
#
# == When it switches
#
# All of these, checked in this order, and the first that fails is the #plan's
# state:
#
# 1. **No turn is in flight anywhere.** `Session.running_turns` — the count
#    /inference prints as sessions on a worker — plus the turns queued for one.
#    Switching under a running turn would not break that turn (it keeps the
#    token it was spawned with), but its next turn would land on a cold cache.
#    A fleet that cannot be read holds too.
# 2. **The pool has been quiet for the prompt-cache TTL** (an hour by default)
#    since the last transcript activity of any Claude Code session. Anthropic's
#    prompt cache is per account and lives an hour; a switch inside that window
#    throws away every session's cache, and one after it throws away nothing,
#    because the cache is already gone.
# 3. **No human switched the pool in the last MANUAL_HOLD.**
# 4. **The current account has a fresh reading**, so the comparison is between
#    two numbers rather than a number and a guess.
# 5. **Some other account is eligible** — active, credentialed, freshly read,
#    neither window spent or above 90% (ClaudeAccountScore#eligible?).
# 6. **The best of those beats the current account by MIN_GAIN or more.**
#    Hysteresis: two near-equal accounts would otherwise swap every hour as each
#    one's usage ticks past the other's.
#
# A current account that cannot serve at all (not active, or its credential
# refused) scores 0 and skips conditions 3 and 4: there is nothing to protect
# by staying on it.
#
# == Racing a session start
#
# The switch runs under the pool lock every rotation takes, so it never
# interleaves with a reactive rotation. It does NOT make a starting session
# wait. A spawn reads `ClaudeAccount.current_account` once and is handed that
# account's token; ClaudeAccount#mark_current! flips `is_current` inside one
# transaction, so that read sees either the old account or the new one — both
# active and valid — and never neither. A session that reads the old account a
# millisecond before the commit simply runs on it: the old account is not
# condemned by a rebalance, and the next spawn picks up the new one. Holding the
# idle check and the switch inside the same lock, with a re-check after the
# candidate probe, keeps that window to the probe-free tail of the sweep.
class AccountRebalanceService
  RUNTIME = ClaudeAuthProvider::RUNTIME

  # How long the pool must have been quiet before a switch is free. Anthropic's
  # prompt cache lives an hour, so a shorter window throws away live caches.
  IDLE_WINDOW = Integer(ENV.fetch("CLAUDE_REBALANCE_IDLE_MINUTES", "60")).minutes

  # How much better (in ClaudeAccountScore points, 0–1) the best account must be
  # than the current one. 0.15 is about 19 points of weekly headroom on its own.
  MIN_GAIN = Float(ENV.fetch("CLAUDE_REBALANCE_MIN_SCORE_GAIN", "0.15"))

  # Off switch, for an operator who wants the pool to move only on quota walls.
  ENABLED = ENV.fetch("CLAUDE_REBALANCE_ENABLED", "true") != "false"

  # How long a human's Switch on /inference holds the pool against a rebalance.
  # Someone who picked an account by hand had a reason the score cannot see, and
  # undoing it an hour later without a word would be the sweep overruling them.
  MANUAL_HOLD = 24.hours

  # Ordered the way #plan reaches them.
  STATES = %i[disabled no_current_account busy fleet_unreadable inside_idle_window manual_hold
    no_current_reading no_candidate current_is_best due].freeze

  # One reading of everything the decision rests on. Read-only: /inference
  # renders it, and #rebalance! acts on it.
  Plan = Data.define(:state, :now, :current, :current_score, :best, :best_score,
    :turns_in_flight, :last_activity_at, :idle_window, :min_gain, :manual_until, :ranking) do
    def due? = state == :due

    # When the idle window ends, or nil when there has been no activity at all.
    def idle_until = last_activity_at && last_activity_at + idle_window

    # The best account's lead over the current one.
    def gain
      return nil if best_score.nil? || current_score.nil?

      (best_score - current_score).round(4)
    end
  end

  def self.plan(now: Time.current)
    new.plan(now: now)
  end

  def initialize(enabled: ENABLED, idle_window: IDLE_WINDOW, min_gain: MIN_GAIN)
    @enabled = enabled
    @idle_window = idle_window
    @min_gain = min_gain
    @logger = StructuredLogger.new({ service: "AccountRebalanceService" })
  end

  # @return [Plan]
  def plan(now: Time.current)
    unless @enabled
      return Plan.new(state: :disabled, now: now, current: nil, current_score: nil, best: nil, best_score: nil,
        turns_in_flight: nil, last_activity_at: nil, idle_window: @idle_window, min_gain: @min_gain,
        manual_until: nil, ranking: [])
    end

    accounts = ClaudeAccount.for_runtime(RUNTIME).order(:priority, :id).to_a
    current = accounts.find(&:is_current?)
    scores = ClaudeAccountScore.for_accounts(accounts, now: now)
    best = accounts
      .reject { |account| account == current }
      .map { |account| scores[account.id] }
      .select(&:eligible?)
      .min_by { |score| [ -score.value, score.account.priority, score.account.id ] }

    # A current account that cannot serve at all — benched, refused, or labelled
    # out of quota — is worth nothing to stay on, whatever its last reading says,
    # and the sampler stops reading a needs_reauth one, so waiting for a fresh
    # reading would wait forever. It also outranks a human's manual pick: the
    # pick has stopped working.
    unusable = current.present? && (!current.active? || current.credential_rejected?)
    current_value = unusable ? 0.0 : current && scores[current.id].value
    in_flight = turns_in_flight
    activity_at = last_activity_at
    manual_until = manual_hold_until(now) unless unusable

    state =
      if current.nil? then :no_current_account
      elsif in_flight.nil? then :fleet_unreadable
      elsif in_flight.positive? then :busy
      elsif activity_at && now - activity_at < @idle_window then :inside_idle_window
      elsif manual_until then :manual_hold
      elsif !unusable && !scores[current.id].fresh? then :no_current_reading
      elsif best.nil? then :no_candidate
      elsif best.value - current_value < @min_gain then :current_is_best
      else :due
      end

    # Every scored account, best first — what /inference lists beside the
    # sentence so the comparison behind it is visible.
    ranking = scores.values.select(&:value)
      .sort_by { |score| [ -score.value, score.account.priority, score.account.id ] }

    Plan.new(
      state: state, now: now, current: current, current_score: current_value,
      best: best&.account, best_score: best&.value, turns_in_flight: in_flight,
      last_activity_at: activity_at, idle_window: @idle_window, min_gain: @min_gain,
      manual_until: manual_until, ranking: ranking
    )
  end

  # Switch the pool to the best account if the plan says it is due.
  #
  # @return [Hash] { rebalanced: true, from:, to:, event: } or { rebalanced: false, state: }
  def rebalance!(now: Time.current)
    result = ClaudeAccount.with_pool_lock(RUNTIME, wait: 5.seconds) { [ rebalance_under_lock(now) ] }
    return result.first if result

    { rebalanced: false, state: :rotation_in_flight }
  end

  private

  def rebalance_under_lock(now)
    plan = plan(now: now)
    return { rebalanced: false, state: plan.state } unless plan.due?

    candidate = plan.best
    # The candidate's reading may be up to an hour old. Read it again before
    # handing it the pool — the probe is also what proves its credential works.
    snapshot = probe(candidate)
    unless snapshot
      @logger.warn("Rebalance candidate could not be probed, staying put", email: candidate.email)
      return { rebalanced: false, state: :candidate_unprobeable }
    end

    fresh = ClaudeAccountScore.new(candidate.reload, snapshot, now: now)
    current_score = plan.current_score
    unless fresh.eligible? && fresh.value - current_score >= @min_gain
      @logger.info("Rebalance candidate's fresh reading no longer clears the bar, staying put",
        email: candidate.email, score: fresh.value, current_score: current_score,
        ineligible: fresh.ineligible_reason)
      return { rebalanced: false, state: :current_is_best }
    end

    # A session may have started while the probe was in flight.
    in_flight = turns_in_flight
    if in_flight.nil? || in_flight.positive?
      @logger.info("A turn started while the rebalance was probing, staying put")
      return { rebalanced: false, state: :busy }
    end

    candidate.mark_current!
    AccountRotationService.reprioritize!(now: now)

    event = AccountRotationEvent.create(
      rotated_from: plan.current,
      rotated_to: candidate,
      reason: "rebalance",
      source: "automatic",
      triggered_by: format("score %.2f → %.2f", current_score, fresh.value)
    )
    @logger.warn("Failed to log rebalance event", errors: event.errors.full_messages) unless event.persisted?
    @logger.info("Rebalanced the account pool", from: plan.current.email, to: candidate.email,
      from_score: current_score, to_score: fresh.value)

    { rebalanced: true, from: plan.current, to: candidate, event: event }
  end

  # Turns on a worker or queued for one, across every runtime — the population
  # /inference counts — or nil when the fleet could not be read. Nil never
  # switches: a monitoring gap must not be mistaken for an idle fleet.
  def turns_in_flight
    turns = Session.running_turns
    turns.on_a_worker + turns.awaiting_a_worker
  rescue StandardError => e
    @logger.warn("Could not read turns in flight, holding", error: e.message)
    nil
  end

  # When a human's most recent Switch stops holding the pool, or nil when the
  # pool's last move was not a human's or the hold has run out.
  def manual_hold_until(now)
    latest = AccountRotationEvent.for_runtime(RUNTIME).order(created_at: :desc).first
    return nil unless latest&.source == "manual"

    until_at = latest.created_at + MANUAL_HOLD
    until_at if until_at > now
  end

  # The last moment any Claude Code session showed transcript activity — the
  # last request that could have warmed the current account's prompt cache.
  def last_activity_at
    Session.where(agent_runtime: RUNTIME).maximum(:last_timeline_entry_at)
  end

  # A fresh reading for `account`, or nil when Anthropic would not give one.
  # QuotaSnapshotService.probe owns the refresh-once-on-refusal guard (#242).
  def probe(account)
    token = account.claude_access_token
    return nil if token.blank?

    QuotaSnapshotService.probe(account, token: token, trigger: "rebalance").first
  rescue StandardError => e
    @logger.warn("Rebalance probe failed", email: account.email, error: e.message)
    nil
  end
end
