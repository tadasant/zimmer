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
# 2. **The pool has been quiet for the prompt-cache TTL** (an hour by default)
#    since the last transcript activity of any Claude Code session. Anthropic's
#    prompt cache is per account and lives an hour; a switch inside that window
#    throws away every session's cache, and one after it throws away nothing,
#    because the cache is already gone.
# 3. **The current account has a fresh reading**, so the comparison is between
#    two numbers rather than a number and a guess.
# 4. **Some other account is eligible** — active, credentialed, freshly read,
#    neither window spent (ClaudeAccountScore#eligible?).
# 5. **The best of those beats the current account by MIN_GAIN or more.**
#    Hysteresis: two near-equal accounts would otherwise swap every hour as each
#    one's usage ticks past the other's.
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

  # Ordered the way #plan reaches them.
  STATES = %i[disabled no_current_account busy inside_idle_window no_current_reading
    no_candidate current_is_best due].freeze

  # One reading of everything the decision rests on. Read-only: /inference
  # renders it, and #rebalance! acts on it.
  Plan = Data.define(:state, :now, :current, :current_score, :best, :best_score,
    :turns_in_flight, :last_activity_at, :idle_window, :min_gain, :candidate_count, :ranking) do
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
    accounts = ClaudeAccount.for_runtime(RUNTIME).order(:priority, :id).to_a
    current = accounts.find(&:is_current?)
    scores = ClaudeAccountScore.for_accounts(accounts, now: now)
    current_score = current && scores[current.id]
    candidates = accounts
      .reject { |account| account == current }
      .map { |account| scores[account.id] }
      .select(&:eligible?)
    best = candidates.min_by { |score| [ -score.value, score.account.priority, score.account.id ] }
    in_flight = turns_in_flight
    activity_at = last_activity_at

    state =
      if !@enabled then :disabled
      elsif current.nil? then :no_current_account
      elsif in_flight.positive? then :busy
      elsif activity_at && now - activity_at < @idle_window then :inside_idle_window
      elsif !current_score.fresh? then :no_current_reading
      elsif best.nil? then :no_candidate
      elsif best.value - current_score.value < @min_gain then :current_is_best
      else :due
      end

    # Every scored account, best first — what /inference lists beside the
    # sentence so the comparison behind it is visible.
    ranking = scores.values.select(&:value)
      .sort_by { |score| [ -score.value, score.account.priority, score.account.id ] }

    Plan.new(
      state: state, now: now, current: current, current_score: current_score&.value,
      best: best&.account, best_score: best&.value, turns_in_flight: in_flight,
      last_activity_at: activity_at, idle_window: @idle_window, min_gain: @min_gain,
      candidate_count: candidates.size, ranking: ranking
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
    current_score = ClaudeAccountScore.new(plan.current, plan.current.latest_snapshot, now: now).value
    unless fresh.eligible? && fresh.value - current_score >= @min_gain
      @logger.info("Rebalance candidate's fresh reading no longer clears the bar, staying put",
        email: candidate.email, score: fresh.value, current_score: current_score,
        ineligible: fresh.ineligible_reason)
      return { rebalanced: false, state: :current_is_best }
    end

    # A session may have started while the probe was in flight.
    if turns_in_flight.positive?
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
  # /inference counts. Unreadable reads as busy: a monitoring gap must never be
  # mistaken for an idle fleet.
  def turns_in_flight
    turns = Session.running_turns
    turns.on_a_worker + turns.awaiting_a_worker
  rescue StandardError => e
    @logger.warn("Could not read turns in flight, treating the fleet as busy", error: e.message)
    1
  end

  # The last moment any Claude Code session showed transcript activity — the
  # last request that could have warmed the current account's prompt cache.
  def last_activity_at
    Session.where(agent_runtime: RUNTIME).maximum(:last_timeline_entry_at)
  end

  # A fresh reading for `account`, or nil when Anthropic would not give one.
  # A refused token gets one refresh first, the way ClaudeUsageSamplerJob does.
  def probe(account)
    token = account.claude_access_token
    return nil if token.blank?

    result = QuotaCheckService.check_with_token(token)
    if result.credential_refused? && account.can_refresh_token? && !account.credential_rejected? && account.refresh_token!
      account.reload
      token = account.claude_access_token
      result = QuotaCheckService.check_with_token(token) if token.present?
    end

    account.record_credential_probe!(result, probed_token: token)
    return nil unless result.success?

    QuotaSnapshotService.save_snapshot(account, result, trigger: "rebalance")
  rescue StandardError => e
    @logger.warn("Rebalance probe failed", email: account.email, error: e.message)
    nil
  end
end
