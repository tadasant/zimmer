# frozen_string_literal: true

# Everything /inference renders, as data — what `GET /api/v1/inference` answers
# and what its writes echo back. Every figure comes off the same objects the
# page and `get_spot_policy` read (ClaudeAccountPool, SpotGateService,
# SpotHoldExplanation, FleetTopUpStatus, SessionGenesis), so the three surfaces
# cannot disagree.
#
# Nothing secret leaves here: no OAuth token, no refresh token, no API key, no
# OpenRouter key — the roster carries emails and verdicts, the key card a
# fingerprint at most, exactly as the page does.
class InferenceReport
  RUNTIMES = RuntimeRegistry::BUNDLES.keys.freeze

  # The runtime a `?runtime=` names, defaulting to Claude Code as the page does.
  def self.normalize_runtime(value)
    RUNTIMES.include?(value) ? value : ClaudeAuthProvider::RUNTIME
  end

  # One account as its card renders it.
  #
  # @param snapshot [ClaudeAccountQuotaSnapshot, nil] the account's latest reading
  # @param is_current [Boolean]
  # @param error [String, nil] a probe's failure, on a refresh response only
  def self.account_json(account, snapshot:, is_current:, error: nil)
    api_key_account = account.codex? && account.codex_api_key_account?

    {
      id: account.id,
      email: account.email,
      runtime: account.runtime,
      priority: account.priority,
      is_current: is_current,
      # The sticky column, and the badge the card wears — which derives from the
      # reading and can outrank the column (ClaudeAccount#effective_status).
      status: account.status,
      effective_status: account.effective_status(snapshot),
      quota_hit_count: account.quota_hit_count,
      api_key_account: api_key_account,
      credentials: {
        state: account.credential_state,
        stored: account.has_valid_config?,
        refused: account.credential_rejected?,
        rejected_at: account.credential_rejected_at&.iso8601,
        rejection_reason: account.credential_rejection_reason,
        verified_at: account.credential_verified_at&.iso8601
      },
      probe_error: error,
      # Codex has no usage-quota probe, so its card renders no windows.
      quota: account.codex? ? nil : quota_json(snapshot),
      login: login_json(account, api_key_account: api_key_account)
    }
  end

  # One login attempt as the panel renders it. The pasted authorization code is
  # a secret the worker consumes; only whether one has been received is reported.
  def self.login_attempt_json(attempt)
    {
      id: attempt.id,
      account_id: attempt.claude_account_id,
      runtime: attempt.runtime,
      status: attempt.status,
      terminal: attempt.terminal?,
      verification_url: attempt.verification_url,
      verification_code: attempt.verification_code,
      awaiting_code: attempt.status == "awaiting_code",
      code_received: attempt.pasted_code.present?,
      error_message: attempt.error_message,
      expires_at: attempt.expires_at&.iso8601,
      created_at: attempt.created_at.iso8601
    }
  end

  def self.quota_json(snapshot)
    return nil unless snapshot

    {
      taken_at: snapshot.created_at.iso8601,
      trigger: snapshot.trigger,
      subscription_type: snapshot.subscription_type,
      rate_limit_tier: snapshot.rate_limit_tier,
      five_hour: window_json(snapshot.utilization_5h, snapshot.status_5h, snapshot.reset_5h),
      seven_day: window_json(snapshot.utilization_7d, snapshot.status_7d, snapshot.reset_7d),
      # The 5-hour bar reads as headroom the account cannot spend once its
      # weekly allowance is gone — the card names the gap, so does this.
      five_hour_headroom_unusable: five_hour_headroom_unusable?(snapshot)
    }
  end

  # A window as the card renders it. `status` is dropped once the window has
  # rolled over, as the badge is: a status recorded for a window that is gone is
  # no longer a fact about the account (InferenceHelper#window_status_badge).
  def self.window_json(utilization, status, reset_at)
    reset_passed = reset_at.present? && reset_at <= Time.current

    {
      utilization: utilization,
      effective_utilization: ClaudeAccountQuotaSnapshot.effective_utilization(utilization, reset_at),
      status: reset_passed ? nil : status,
      reset_at: reset_at&.iso8601,
      reset_passed: reset_passed
    }
  end

  def self.five_hour_headroom_unusable?(snapshot)
    return false unless snapshot.seven_day_window_spent?

    effective = ClaudeAccountQuotaSnapshot.effective_utilization(snapshot.utilization_5h, snapshot.reset_5h)
    effective.nil? || effective < 1.0
  end

  def self.login_json(account, api_key_account:)
    # An API-key account carries its credential statically; the panel is skipped.
    return { available: false, active_attempt: nil, last_attempt: nil } if api_key_account

    attempts = account.runtime_login_attempts.order(:created_at)
    active = attempts.active.last
    last = attempts.last

    {
      available: true,
      active_attempt: active && login_attempt_json(active),
      last_attempt: last && { id: last.id, status: last.status, error_message: last.error_message }
    }
  end

  def initialize(runtime:)
    @runtime = runtime
    @setting = AppSetting.current
  end

  attr_reader :runtime, :setting

  def pi? = runtime == PiAuthProvider::RUNTIME

  # The whole page for `runtime`. The Pi tab manages a provider key instead of a
  # pool, so it carries the key's state and no roster; the other tabs the reverse.
  def as_json
    {
      runtime: runtime,
      runtimes: RUNTIMES.map { |key| { key: key, label: RuntimeRegistry.label_for(key) } },
      accounts: pi? ? nil : accounts.map { |account| account_json(account) },
      pool: pi? ? nil : pool_json,
      rotation_log: pi? ? nil : rotation_log_json,
      openrouter_key: pi? ? openrouter_key_json : nil,
      spot_policy: spot_policy_json,
      fleet_top_up: fleet_top_up_json,
      genesis_classes: genesis_classes_json
    }
  end

  def accounts
    @accounts ||= ClaudeAccount.for_runtime(runtime).order(:priority).to_a
  end

  def current_account
    @current_account ||= ClaudeAccount.current_account(runtime)
  end

  # One query for the readings the roster renders and the pool figure averages.
  def snapshots
    @snapshots ||= ClaudeAccountPool.latest_snapshots(accounts)
  end

  def account_json(account, error: nil)
    self.class.account_json(account, snapshot: snapshots[account.id], is_current: account == current_account, error: error)
  end

  # The Account Pool card: the four counts, the averaged windows, when held work
  # resumes, the dollar view, and the dry-pool banner when no account can serve.
  def pool_json
    status_counts = Hash.new(0)
    accounts.each { |account| status_counts[account.effective_status(snapshots[account.id])] += 1 }
    measure = ClaudeAccountPool.new(accounts: accounts, snapshots: snapshots).measure
    dry = ApplicationController.helpers.dry_pool(runtime, accounts, snapshots)

    {
      total: accounts.size,
      active: status_counts["active"],
      quota_exceeded: status_counts["quota_exceeded"],
      needs_reauth: status_counts["needs_reauth"],
      five_hour_utilization: measure.five_hour,
      weekly_utilization: measure.weekly,
      worst_five_hour_utilization: measure.worst_five_hour,
      worst_weekly_utilization: measure.worst_weekly,
      read_count: measure.read_count,
      servable_count: measure.servable_count,
      weekly_spent_count: measure.weekly_spent_count,
      capacity_now: measure.capacity_now?,
      next_capacity_at: measure.next_capacity_at&.iso8601,
      next_weekly_reset: measure.next_weekly_reset&.iso8601,
      windows: QuotaCapacityModel.windows(measure: measure, setting: setting).transform_values(&:to_h),
      dry: dry && { reasons: dry.reasons, breakdown: dry.breakdown, recovery: dry.recovery }
    }
  end

  # The Rotation Log table: the runtime's own most-recent slice, filtered in SQL
  # before the limit so a busy runtime cannot crowd another off the page.
  def rotation_log_json
    AccountRotationEvent.for_runtime(runtime).order(created_at: :desc).limit(50)
      .includes(:rotated_from, :rotated_to).map do |event|
      session_id = event.triggered_by.to_s.delete_prefix("session:") if event.triggered_by.to_s.start_with?("session:")
      {
        id: event.id,
        at: event.created_at.iso8601,
        from: { email: event.from_email, deleted: event.from_deleted? },
        to: { email: event.to_email, deleted: event.to_deleted? },
        reason: event.reason,
        source: event.source,
        triggered_by: event.triggered_by,
        session_id: session_id&.to_i
      }
    end
  end

  # The Pi tab's one object, which carries no secret value by construction
  # (ManagedSecret::Status).
  def openrouter_key_json
    status = ManagedSecret.openrouter_key.status

    {
      variable: status.variable,
      present: status.present?,
      provider_label: status.provider_label,
      provider_badge: status.provider_badge,
      fingerprint: status.fingerprint,
      path: status.path,
      project_id: status.project_id,
      location: status.location,
      last_write: status.last_write && { at: status.last_write.created_at.iso8601, action: status.last_write.action },
      writable: status.writable?,
      deletable: status.deletable?,
      write_reason: status.write_reason,
      missing_permissions: status.missing_permissions
    }
  end

  # The spot gate card: the six knobs, the live decision, which ceiling holds
  # spot work and what lifts it, and the dormant populations — the same objects
  # `get_spot_policy` renders.
  def spot_policy_json
    decision = SpotGateService.evaluate
    paused_count = SpotSessionPause.paused_count
    held_count = SpotSessionHold.held_count
    overdue_hold_count = SpotSessionHold.overdue_count
    preempted_count = SpotSessionPause.preempted_count
    starvation = SpotHoldExplanation::Starvation.read(setting: setting)
    explanation = SpotHoldExplanation.new(decision, paused_count: paused_count, held_count: held_count,
      overdue_hold_count: overdue_hold_count, preempted_count: preempted_count, starvation: starvation)
    cap = setting.spot_max_concurrent_sessions

    {
      gating_enabled: setting.spot_gating_enabled,
      five_hour_reserve_pct: setting.spot_reserve_five_hour_pct,
      weekly_reserve_pct: setting.spot_reserve_weekly_pct,
      max_concurrent_sessions: cap,
      preemption_enabled: setting.spot_preemption_enabled,
      starvation_age_ceiling_hours: setting.spot_starvation_age_ceiling_hours,
      worker_slots: RunningTurns.worker_slots,
      ceiling_out_of_reach: RunningTurns.ceiling_out_of_reach?(cap),
      effective_ceiling: RunningTurns.effective_ceiling(cap),
      decision: decision.to_h,
      hold: explanation.lines.map { |line| { label: line.label, sentence: line.sentence } },
      paused_count: paused_count,
      preempted_count: preempted_count,
      held_count: held_count,
      overdue_hold_count: overdue_hold_count,
      sessions_asleep: explanation.sessions_asleep,
      sessions_preempted: explanation.sessions_preempted,
      sessions_held: explanation.sessions_held,
      sessions_starved: explanation.sessions_starved,
      starvation: {
        ceiling_hours: starvation.ceiling&.in_hours&.to_i,
        starved_count: starvation.starved_count,
        oldest_hold_age_seconds: starvation.oldest_hold_age&.to_i,
        occupants: starvation.occupants.map(&:to_s)
      }
    }
  end

  # The backlog top-up card: the four knobs and where the fleet sits against
  # them, from the one reading FleetIdleMonitor decides on.
  def fleet_top_up_json
    status = FleetTopUpStatus.current(setting: setting)

    {
      max_running_sessions: setting.fleet_idle_max_sessions,
      idle_minutes: setting.fleet_idle_threshold_minutes,
      min_fire_interval_minutes: setting.fleet_idle_min_fire_interval_minutes,
      quiet_backlog_interval_minutes: setting.fleet_idle_quiet_backlog_interval_minutes,
      state: status.state,
      running_sessions: status.running_sessions,
      awaiting_sessions: status.awaiting_sessions,
      asleep_sessions: status.asleep_sessions,
      headroom: status.headroom,
      worker_slots: status.worker_slots,
      ceiling_out_of_reach: status.ceiling_out_of_reach?,
      effective_ceiling: status.effective_ceiling,
      under_ceiling_since: status.under_ceiling_since&.iso8601,
      last_fired_at: status.last_fired_at&.iso8601,
      next_fire_at: status.next_fire_at&.iso8601,
      cadence: status.cadence_phrase,
      quiet_cadence: status.quiet_cadence_phrase,
      sentence: status.sentence
    }
  end

  # Every genesis kind with the class it resolves to. The page offers a button
  # for the settable kinds only; `settable` says which, as the tool's table does.
  def genesis_classes_json
    classes = SessionGenesis.effective_classes(setting.genesis_class_overrides)
    counts = Session.genesis_counts

    {
      overrides: setting.genesis_class_overrides || {},
      kinds: SessionGenesis::KINDS.map do |kind|
        {
          key: kind.key,
          label: kind.label,
          description: kind.description,
          default_class: kind.default_class,
          class: classes[kind.key],
          overridden: classes[kind.key] != kind.default_class,
          settable: SessionGenesis.settable?(kind.key),
          live_sessions: counts[kind.key].to_i
        }
      end
    }
  end
end
