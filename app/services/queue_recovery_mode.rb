# frozen_string_literal: true

# The manual escape hatch for a runaway job queue.
#
# WHAT IT IS
# ----------
# Queue recovery mode halts the *demand-side* GoodJob queues -- `pollers`,
# `triggers` and `default` -- while deliberately leaving `agents` running, so an
# operator (or an agent session they start for the purpose) can look at why the
# instance got overwhelmed and clean up the cause before the backlog is allowed to
# drain again.
#
# The crux of the design is that one queue stays live. Pausing *every* queue would
# also pause `agents`, which is the queue AgentSessionJob runs on -- so the mode
# would halt the very investigation it exists to enable. `agents` is not a source of
# queue demand anyway: it holds one long-running job per session, and sessions are
# started by a human or by an already-running agent, never by the backlog.
#
# NAMING -- read this before grepping
# -----------------------------------
# "Recovery" already means something else in this codebase, and it is NOT this:
# `DeploymentRecoveryJob`, `CleanupOrphanedSessionsJob` and
# `metadata["paused_by"] = "recovery"` are all about recovering *sessions* after a
# deploy or a crash. This concept is qualified as *queue* recovery mode everywhere
# -- class, column, routes, MCP actions, UI copy -- so the two never read as the
# same thing. Nothing here touches session state.
#
# MECHANISM
# ---------
# The halt itself is GoodJob's own pause feature (GoodJob 4.19's `GoodJob.pause` /
# `GoodJob.paused?`, persisted in `good_job_settings` and enforced in the dequeue
# query by `GoodJob::Job.exclude_paused`). It is enabled by
# `config.good_job.enable_pauses` in config/application.rb; without that flag
# GoodJob silently ignores every pause, so `enabled?` below refuses to enter rather
# than reporting a halt that isn't happening.
#
# Pausing stops *execution*, not *enqueue*. Cron keeps ticking and jobs keep piling
# up in `good_job_jobs` -- which is fine and is the point: the queue is frozen for
# inspection, not truncated. The periodic jobs that could pile up worst are already
# singletons (`good_job_control_concurrency_with total_limit: 1`), so at most one of
# each poller can be waiting when the mode is lifted.
#
# Zimmer's own metadata -- who entered, why, and when it auto-exits -- lives in the
# `app_settings.queue_recovery_mode` JSONB column. GoodJob's pause rows are the
# thing the worker enforces; this column is the thing a human reads.
#
# THE BACKSTOP
# ------------
# Production must not be left halted because someone closed their laptop. Every
# entry carries a TTL (default DEFAULT_TTL, hard-capped at MAX_TTL) and there are
# two independent paths that act on it:
#
#   1. QueueRecoveryModeExpiryJob, on a cron, on the `agents` queue -- the one queue
#      recovery mode does not pause.
#   2. ApplicationController#reconcile_queue_recovery_mode, a throttled check in the
#      web process, which needs no worker thread at all.
#
# Two paths because each covers the other's failure: (1) starves if all `agents`
# threads are occupied by long sessions (the runaway-session incident), and (2)
# needs web traffic. On top of both, `status` computes `active` from the clock, so
# no surface can report "halted" for a window that has already expired even if
# neither path has run yet.
class QueueRecoveryMode
  # The queues a halt applies to: everything that creates or processes background
  # demand. `agents` is deliberately absent -- see the class comment.
  HALTED_QUEUES = %w[pollers triggers default].freeze

  # The queue that keeps running so sessions can still be started and can still run
  # while the rest of the system is frozen.
  LIVE_QUEUES = %w[agents].freeze

  DEFAULT_TTL = 60.minutes
  MIN_TTL = 5.minutes
  MAX_TTL = 4.hours

  # Where the metadata lives on the AppSetting singleton.
  SETTING_KEY = :queue_recovery_mode

  # Reasons `exit!` can be called with, for the Slack alert and the log line.
  EXIT_REASONS = { manual: "manual", expired: "expired" }.freeze

  # A read-only snapshot. `active` is already clock-adjusted, so callers never have
  # to remember to compare `expires_at` themselves.
  Status = Data.define(
    :active, :entered_at, :expires_at, :reason, :entered_by, :halted_queues, :paused_queues
  ) do
    def active? = active

    # Seconds until the auto-exit fires; nil when not active.
    def expires_in
      return nil unless active && expires_at

      [ (expires_at - Time.current).to_i, 0 ].max
    end

    def as_json(*)
      {
        active: active,
        entered_at: entered_at&.iso8601,
        expires_at: expires_at&.iso8601,
        expires_in_seconds: expires_in,
        reason: reason,
        entered_by: entered_by,
        halted_queues: halted_queues,
        paused_queues: paused_queues,
        live_queues: LIVE_QUEUES
      }
    end
  end

  # Raised when the mode cannot be entered -- currently only when GoodJob pauses are
  # not enabled, which would make a "halt" a no-op the operator would trust.
  class NotAvailable < StandardError; end

  class << self
    # Whether this deployment can actually halt a queue. False means GoodJob would
    # accept the pause rows and then ignore them at dequeue.
    def enabled?
      GoodJob.configuration.enable_pauses
    rescue StandardError => e
      Rails.logger.error("[queue_recovery_mode] could not read GoodJob configuration: #{e.message}")
      false
    end

    def active?
      status.active?
    end

    # The current snapshot. Never raises and never writes: it is read on every page
    # render (the global banner) and by the health surfaces.
    def status
      stored = stored_metadata
      entered_at = parse_time(stored["entered_at"])
      expires_at = parse_time(stored["expires_at"])
      active = entered_at.present? && (expires_at.nil? || expires_at.future?)

      Status.new(
        active: active,
        entered_at: entered_at,
        expires_at: expires_at,
        reason: stored["reason"].presence,
        entered_by: stored["entered_by"].presence,
        halted_queues: HALTED_QUEUES,
        paused_queues: goodjob_paused_queues
      )
    end

    # Halt the demand-side queues.
    #
    # Re-entering while already active is an *extension*, not an error: the TTL is
    # recomputed from now, which is how an operator who needs longer buys it.
    #
    # @param reason [String, nil] free text shown in the banner and the alert
    # @param ttl [ActiveSupport::Duration, Numeric, nil] clamped to MIN_TTL..MAX_TTL
    # @param actor [String, nil] who asked (a surface name, an API key fingerprint)
    # @return [Status]
    def enter!(reason: nil, ttl: nil, actor: nil)
      unless enabled?
        raise NotAvailable, "GoodJob pauses are not enabled on this instance " \
          "(config.good_job.enable_pauses), so queues cannot be halted."
      end

      duration = clamp_ttl(ttl)
      was_active = active?
      now = Time.current

      with_settings do |record, stored|
        record.public_send(:"#{SETTING_KEY}=", stored.merge(
          # An extension keeps the original entry time; the incident started when it
          # started, and the banner should not keep resetting to "just now".
          "entered_at" => (was_active && stored["entered_at"].presence) || now.iso8601,
          "expires_at" => (now + duration).iso8601,
          "reason" => reason.to_s.strip.presence,
          "entered_by" => actor.to_s.strip.presence
        ))
      end

      HALTED_QUEUES.each { |queue| GoodJob.pause(queue: queue) }

      snapshot = status
      log(:warn, was_active ? "extended" : "entered", snapshot)
      alert_entered(snapshot, extended: was_active)
      snapshot
    end

    # Resume normal processing.
    #
    # Idempotent, and deliberately does NOT require `enabled?`: an instance that was
    # halted and then had pauses turned off must still be able to unpause.
    #
    # @param actor [String, nil] who asked
    # @param exit_reason [Symbol] :manual or :expired
    # @return [Status] the (inactive) snapshot after exiting
    def exit!(actor: nil, exit_reason: :manual)
      before = status

      HALTED_QUEUES.each { |queue| unpause(queue) }
      with_settings { |record, _stored| record.public_send(:"#{SETTING_KEY}=", {}) }

      snapshot = status
      # Only announce a transition that actually happened. Exiting a mode that was
      # already off is a no-op an operator does not need paged about.
      if before.entered_at.present?
        log(:info, "exited (#{EXIT_REASONS.fetch(exit_reason, exit_reason)})", before)
        alert_exited(before, exit_reason: exit_reason, actor: actor)
      end
      snapshot
    end

    # The TTL backstop. Returns true when it actually exited.
    #
    # Keyed off the stored metadata rather than `status.active?` so it fires exactly
    # on the state that needs fixing: metadata present, window elapsed, queues still
    # paused.
    def expire_if_due!
      stored = stored_metadata
      return false if stored["entered_at"].blank?

      expires_at = parse_time(stored["expires_at"])
      return false if expires_at.nil? || expires_at.future?

      exit!(actor: "auto-expiry", exit_reason: :expired)
      true
    rescue StandardError => e
      # This runs on a cron and on the web request path. It must never be the reason
      # a page 500s or a job retries forever.
      Rails.logger.error("[queue_recovery_mode] expiry check failed: #{e.class}: #{e.message}")
      Rails.error.report(e, handled: true, severity: :error)
      false
    end

    # Clamp a caller-supplied TTL into the allowed window. Accepts a Duration, a
    # number of seconds, or nil for the default.
    def clamp_ttl(ttl)
      return DEFAULT_TTL if ttl.blank?

      seconds = ttl.respond_to?(:to_i) ? ttl.to_i : DEFAULT_TTL.to_i
      seconds.clamp(MIN_TTL.to_i, MAX_TTL.to_i).seconds
    end

    private

    # The raw JSONB map, tolerant of the window where new code boots against a
    # schema that predates the column's migration (the same defensiveness
    # AppSetting#extension_enabled? applies to `extension_states`).
    def stored_metadata
      record = AppSetting.current
      return {} unless record.respond_to?(:has_attribute?) && record.has_attribute?(SETTING_KEY)

      (record.public_send(SETTING_KEY) || {}).with_indifferent_access
    rescue ActiveRecord::StatementInvalid, ActiveRecord::NoDatabaseError => e
      Rails.logger.warn("[queue_recovery_mode] could not read settings: #{e.message}")
      {}
    end

    # Mutate the metadata under a row lock, so two operators entering at the same
    # moment cannot interleave into a half-written window.
    def with_settings
      record = AppSetting.editable
      record.save! if record.new_record?
      return unless record.has_attribute?(SETTING_KEY)

      record.with_lock do
        stored = (record.public_send(SETTING_KEY) || {}).with_indifferent_access
        yield(record, stored)
        record.save!
      end
    end

    # GoodJob raises if asked to unpause something it never paused in some versions;
    # it is also entirely possible an operator already unpaused by hand in the
    # GoodJob dashboard. Either way, exiting must not blow up half way through.
    def unpause(queue)
      GoodJob.unpause(queue: queue)
    rescue StandardError => e
      Rails.logger.error("[queue_recovery_mode] failed to unpause #{queue}: #{e.message}")
    end

    # What GoodJob *actually* has paused right now, so the health surfaces can show
    # the truth rather than only Zimmer's intent — including a queue an operator
    # paused by hand from the GoodJob dashboard.
    def goodjob_paused_queues
      Array(GoodJob.paused(:queues))
    rescue StandardError => e
      Rails.logger.error("[queue_recovery_mode] could not read GoodJob pauses: #{e.message}")
      []
    end

    def parse_time(value)
      return nil if value.blank?

      Time.iso8601(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def log(level, event, snapshot)
      Rails.logger.public_send(
        level,
        "[queue_recovery_mode] #{event}: queues=#{HALTED_QUEUES.join(',')} " \
        "expires_at=#{snapshot.expires_at&.iso8601} reason=#{snapshot.reason.inspect} " \
        "entered_by=#{snapshot.entered_by.inspect}"
      )
    end

    def alert_entered(snapshot, extended:)
      AlertService.raise_alert(
        extended ? "Queue recovery mode extended" : "Queue recovery mode ENTERED",
        details: [
          "Background job execution is halted on: *#{HALTED_QUEUES.join(", ")}*.",
          "The `#{LIVE_QUEUES.join(", ")}` queue is still running, so sessions can be started and can run.",
          "Auto-exit at *#{snapshot.expires_at&.iso8601}* (in #{humanized_minutes(snapshot.expires_in)}).",
          snapshot.reason.present? ? "Reason: #{snapshot.reason}" : nil,
          snapshot.entered_by.present? ? "Entered by: #{snapshot.entered_by}" : nil
        ].compact.join("\n"),
        source: name,
        # A fresh key per entry so a second incident later in the dedup window is
        # never swallowed, while the enter/extend of one incident collapses.
        dedup_key: "queue_recovery_mode_entered:#{snapshot.entered_at&.iso8601}"
      )
    end

    def alert_exited(before, exit_reason:, actor:)
      expired = exit_reason == :expired

      AlertService.raise_alert(
        expired ? "Queue recovery mode auto-exited (TTL)" : "Queue recovery mode exited",
        details: [
          "Background job execution resumed on: *#{HALTED_QUEUES.join(", ")}*.",
          expired ? "This was the TTL backstop, not an operator — the queue backlog is now draining unattended." : nil,
          before.entered_at.present? ? "Halted since: #{before.entered_at.iso8601}" : nil,
          before.reason.present? ? "Reason given on entry: #{before.reason}" : nil,
          actor.present? ? "Exited by: #{actor}" : nil
        ].compact.join("\n"),
        source: name,
        dedup_key: "queue_recovery_mode_exited:#{before.entered_at&.iso8601}"
      )
    end

    def humanized_minutes(seconds)
      return "unknown" if seconds.nil?

      "#{(seconds / 60.0).ceil} min"
    end
  end
end
