# frozen_string_literal: true

# ErrorReporter is the single seam through which Zimmer surfaces failures to the
# self-hosted GlitchTip instance (via the Sentry SDK).
#
# Zimmer is not request-driven like the web-app — its failures live in GoodJob
# background jobs and the session-lifecycle subsystem, much of it inside
# deliberate "log but don't fail" swallow-rescues that would otherwise be
# invisible (this is exactly what let the 2026-06-10 stalled-sessions incident
# run unnoticed). Routing those rescues and StructuredLogger#error through here
# makes them visible in GlitchTip without changing their non-fatal behavior.
#
# Every method is a hard no-op when Sentry is not initialized (i.e. when
# SENTRY_DSN_BACKEND is unset), so callers can wire it in unconditionally. And
# when the SDK *is* initialized outside production/staging — an agent session
# inherits the production DSN from its container — the environment allowlist in
# config/initializers/sentry.rb drops the event at the client, so nothing these
# methods hand to Sentry leaves the process.
module ErrorReporter
  module_function

  # Report a rescued exception (preferred — carries a backtrace).
  #
  #   rescue => e
  #     Rails.logger.error("...")
  #     ErrorReporter.report_exception(e, context: { session_id: id })
  #   end
  def report_exception(exception, context: {}, level: :error)
    return unless reporting_enabled?

    Sentry.capture_exception(exception, level: level, extra: context.compact)
  rescue => reporting_error
    # Never let error reporting itself raise into a caller that was swallowing.
    Rails.logger.error("[ErrorReporter] Failed to report exception: #{reporting_error.message}")
    nil
  end

  # Report a contextual message when there is no exception object to attach.
  def report_message(message, context: {}, level: :error)
    return unless reporting_enabled?

    Sentry.capture_message(message, level: level, extra: context.compact)
  rescue => reporting_error
    Rails.logger.error("[ErrorReporter] Failed to report message: #{reporting_error.message}")
    nil
  end

  def reporting_enabled?
    defined?(Sentry) && Sentry.initialized?
  end
end
