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
# next wording change is a Slack message instead of an archaeology session.
#
# This deliberately does not try to classify better. It makes the unknown
# announce itself.
#
# == Noise budget ==
#
# The dedup key is derived from (kind, summary) and deliberately excludes the
# session id, so a fleet-wide wave of the same unknown failure mode collapses
# into one #eng-alerts message per AlertService::DEDUP_WINDOW rather than one
# per session. A genuinely *new* failure mode has a different summary and pages
# on its own.
class UnclassifiedFailureReporter
  # Cap on how much unmatched output travels into the alert. Slack truncates at
  # 3000 chars per section and the alert also carries context lines; this keeps
  # the operative error visible without dumping a whole stderr log.
  MAX_OUTPUT_CHARS = 1200

  # Secret shapes scrubbed from the unmatched output before it leaves the box.
  #
  # This is the first code path that routes raw agent-process stderr and
  # transcript text to Slack — session logs already carry both, but they stay
  # inside Zimmer's own UI. A failing stdio MCP server whose stderr echoes its
  # spawn command or request headers would otherwise put an injected credential
  # in #eng-alerts verbatim. Truncation is not redaction, so scrub first.
  #
  # Deliberately shape-based rather than value-based: the reporter has no list
  # of the session's secrets to match against, and the interesting case is a
  # credential Zimmer never knew about.
  SECRET_PATTERNS = [
    /\bsk-[A-Za-z0-9_\-]{8,}/,
    /\bgh[pousr]_[A-Za-z0-9]{8,}/,
    /\bxox[abeoprs]-[A-Za-z0-9-]{8,}/,
    /\bAIza[A-Za-z0-9_\-]{8,}/,
    /\b(?:ya29|1\/\/)[A-Za-z0-9_\-.]{8,}/,
    /(?<=[Bb]earer )\S+/,
    /(?<=[Aa]uthorization: )\S+/,
    /(?<=-----BEGIN )[A-Z ]*(?=PRIVATE KEY-----)/
  ].freeze

  # Key=value / key: value shapes whose VALUE is replaced, keeping the key so
  # the reader still learns which credential was involved.
  SECRET_ASSIGNMENT_PATTERN =
    /((?:api[_-]?key|access[_-]?token|auth[_-]?token|token|secret|password|passwd|pwd|credential)["']?\s*[:=]\s*["']?)([^\s"',;}]+)/i

  # Credentials embedded in a URL: https://user:pass@host
  URL_CREDENTIAL_PATTERN = %r{(?<=://)[^\s/:@]+:[^\s/@]+(?=@)}

  REDACTED = "[REDACTED]"

  class << self
    # Report a failure that no classifier recognized.
    #
    # @param kind [String] the classifier family that came up empty, e.g.
    #   "process exit" or "recovery contradiction". Part of the dedup key.
    # @param summary [String] a short, low-cardinality description of this
    #   particular unknown — e.g. "exit code: 2". Also part of the dedup key, so
    #   it must NOT contain a session id, pid, or timestamp.
    # @param source [String] the call site, e.g. "ProcessLifecycleManager#handle_exit"
    # @param session [Session, nil] the affected session, linked in the alert
    # @param output [String, nil] the unmatched output (stderr tail, transcript
    #   error text) that no pattern recognized
    # @param logger [StructuredLogger, nil] logger for the loud log line
    # @return [Boolean] whether the alert was sent
    def report(kind:, summary:, source:, session: nil, output: nil, logger: nil)
      trimmed = redact(output).truncate(MAX_OUTPUT_CHARS).presence

      log_loudly(kind: kind, summary: summary, source: source, session: session, output: trimmed, logger: logger)

      AlertService.raise_alert(
        "Unclassified failure: #{kind}",
        details: alert_details(kind: kind, summary: summary, session: session, output: trimmed),
        source: source,
        dedup_key: dedup_key(kind, summary)
      )
    rescue => e
      # Self-guarding, like SessionStateMachine#report_swallowed_side_effect.
      # Announcing a failure must never become a second way for that failure to
      # blow up, and callers must not have to know that.
      Rails.logger.error("[UnclassifiedFailureReporter] Failed to report unclassified #{kind}: #{e.message}")
      false
    end

    # Strip credential-shaped substrings from output bound for Slack.
    # @param output [String, nil]
    # @return [String] always a String, possibly empty
    def redact(output)
      text = output.to_s.strip
      return text if text.empty?

      SECRET_PATTERNS.each { |pattern| text = text.gsub(pattern, REDACTED) }
      text = text.gsub(SECRET_ASSIGNMENT_PATTERN) { "#{Regexp.last_match(1)}#{REDACTED}" }
      text.gsub(URL_CREDENTIAL_PATTERN, REDACTED)
    end

    private

    def log_loudly(kind:, summary:, source:, session:, output:, logger:)
      message = "No classifier matched this #{kind} — unclassified failure"
      fields = { kind: kind, summary: summary, source: source, session_id: session&.id, unmatched_output: output }.compact

      if logger.respond_to?(:error)
        logger.error(message, **fields)
      else
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

    def alert_details(kind:, summary:, session:, output:)
      lines = []
      lines << "No classifier matched this #{kind}, so the failure was handled by the generic path."
      lines << ""
      lines << "*What happened:* #{summary}"
      lines << "*Unmatched output:*\n```\n#{output}\n```" if output
      lines << ""
      lines << "This usually means an upstream wording or exit-code change outran a pattern in " \
               "the retry strategies. Compare the output above against the classifiers before " \
               "assuming the session simply failed."
      if session
        lines << ""
        lines << "<#{AppUrl.base_url}/sessions/#{session.id}|View session #{session.id} in Zimmer>"
      end
      lines.join("\n")
    end

    # (kind, summary) only — see the noise budget note in the class docs.
    def dedup_key(kind, summary)
      "unclassified_failure_#{Digest::SHA256.hexdigest("#{kind}:#{summary}")[0..15]}"
    end
  end
end
