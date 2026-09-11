# frozen_string_literal: true

# Announces a failure that no classifier recognized.
#
# Zimmer decides how a session died by matching known shapes against the
# runtime's human-readable output: stderr strings, transcript API-error prose,
# exit codes. Every one of those classifiers can go stale — the CLI rewords a
# message and the pattern that used to match stops matching. When that happens
# the affected branch simply isn't taken, and the session dies down the generic
# path looking exactly like an ordinary failure. Nothing logs "I didn't
# recognize this", and nothing alerts.
#
# That is how a capped account was misclassified as a transient rate limit on
# 2026-06-14 and burned six retries before failing (see
# ApiErrorRetryService::ACCOUNT_QUOTA_LIMIT_PATTERN). The fix for that specific
# wording was a better regex; the fix for the *class* of bug is this: when no
# classifier matches, say so out loud, and carry the unmatched output so the
# next wording change is a page instead of an archaeology session.
#
# This deliberately does not try to classify better. It makes the unknown
# announce itself.
#
# == Noise budget ==
#
# The reported message is the KIND alone — never the session id, never the summary
# — so a fleet-wide wave of the same unknown collapses into one GlitchTip issue
# rather than one per session. The summary rides in the context, where it is what
# tells two failure modes of the same kind apart. A genuinely new mode still pages
# on its own: every occurrence writes its own ERROR record, and that is the half
# that pages per occurrence.
class UnclassifiedFailureReporter
  class << self
    # Report a failure that no classifier recognized.
    #
    # @param kind [String] the classifier family that came up empty, e.g.
    #   "process exit" or "recovery contradiction". This is the reported message,
    #   and therefore what GlitchTip groups on.
    # @param summary [String] a short, low-cardinality description of this
    #   particular unknown — e.g. "exit code: 2". Reported as context and logged,
    #   so it must NOT contain a session id, pid, or timestamp.
    # @param source [String] the call site, e.g. "ProcessLifecycleManager#handle_exit"
    # @param session [Session, nil] the affected session, linked in the alert
    # @param output [String, nil] the unmatched output (stderr tail, transcript
    #   error text) that no pattern recognized
    # @param logger [StructuredLogger, nil] logger for the loud log line
    # @return [Boolean] true once the unknown has been reported
    def report(kind:, summary:, source:, session: nil, output: nil, logger: nil)
      # The unmatched output goes through AlertSnippet rather than being
      # hand-pasted into the prose. AlertSnippet owns redaction, clamping and
      # UTF-8 coercion — and it has to: this output is raw agent-process stderr,
      # which arrives as bytes and can end mid-multibyte-character when
      # BoundedSubprocess kills a process group on deadline. Re-implementing any
      # of that here would be a second, weaker copy of a security-relevant seam.
      log_loudly(
        kind: kind, summary: summary, source: source, session: session,
        output: AlertSnippet.build(output.presence), logger: logger
      )
      true
    rescue => e
      # Self-guarding, like SessionStateMachine#report_swallowed_side_effect.
      # Announcing a failure must never become a second way for that failure to
      # blow up, and callers must not have to know that.
      Rails.logger.error("[UnclassifiedFailureReporter] Failed to report unclassified #{kind}: #{e.message}")
      false
    end

    private

    # The single emission: one ERROR record — which is what pages, through the
    # Grafana rule on Zimmer's error logs — and one GlitchTip event carrying the
    # same fields. A StructuredLogger does both halves itself (StructuredLogger#error
    # routes to ErrorReporter), so the explicit report below is only for the plain
    # Rails.logger path; doing both would open two issues for one event.
    def log_loudly(kind:, summary:, source:, session:, output:, logger:)
      message = "Unclassified failure: #{kind}"
      fields = {
        kind: kind,
        summary: summary,
        source: source,
        session_id: session&.id,
        unmatched_output: output,
        details: alert_details(kind: kind, summary: summary, session: session)
      }.compact

      if logger.is_a?(StructuredLogger)
        logger.error(message, **fields)
      else
        # Reported before the log line, not after: ErrorReporter swallows its own
        # failures and cannot raise, so ordering it first keeps the GlitchTip half
        # alive even when the logger is the thing that is broken.
        ErrorReporter.report_message(message, level: :error, context: fields)
        Rails.logger.error("[UnclassifiedFailureReporter] #{message} #{fields.inspect}")
      end
    rescue => e
      # Reporting must never be able to mask the failure it is reporting — not
      # even when the logger is the thing that is broken.
      begin
        Rails.logger.error("[UnclassifiedFailureReporter] Failed to log unclassified #{kind}: #{e.message}")
      rescue StandardError
        nil
      end
    end

    def alert_details(kind:, summary:, session:)
      lines = []
      lines << "No classifier matched this #{kind}, so the failure was handled by the generic path."
      lines << ""
      lines << "What happened: #{summary}"
      lines << ""
      lines << "This usually means an upstream wording or exit-code change outran a pattern in " \
               "the retry strategies. Compare `unmatched_output` against the classifiers " \
               "before assuming the session simply failed."
      if session
        lines << ""
        lines << "Session: #{AppUrl.base_url}/sessions/#{session.id}"
      end
      lines.join("\n")
    end
  end
end
