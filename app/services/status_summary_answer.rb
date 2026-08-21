# frozen_string_literal: true

# What counts as an answer to "write the Status panel for this session", and
# what is the runtime refusing to answer at all.
#
# Both paths that can produce a blurb hand their raw text through here: the fork
# path (SessionStatusSummaryHarvestJob, reading the last assistant message a
# summary fork wrote) and the pool-independent one-shot path
# (SessionStatusSummaryGenerator's headless mode, reading `claude -p` stdout).
# They are separate mechanisms that fail the same way — a runtime out of quota
# prints its limit line where the answer belongs — so the test for it lives in
# one place rather than being re-derived per caller.
#
# Publishing a refusal as the blurb is the specific defect this guards. A
# refusal stored as a summary is stamped at the requested line count, i.e.
# labelled CURRENT, so `stale?` is false and nothing ever replaces it. 73
# sessions in this deployment were showing "You've hit your session limit" as
# their status when that was found.
module StatusSummaryAnswer
  # Hard cap on stored summary text. The prompt asks for 2-3 sentences; this is
  # the backstop for a model that answered with an essay, so the panel cannot
  # push the rest of the page off screen.
  MAX_SUMMARY_CHARS = 1200

  # A refusal is one short line. A real answer is 2-3 sentences carrying markdown
  # links, and is an order of magnitude longer — so length is what keeps the
  # patterns off a genuine summary that happens to be ABOUT a session which hit a
  # limit. Getting that judgement wrong costs a regeneration, never a wrong blurb.
  MAX_REFUSAL_CHARS = 200

  # The refusals a runtime writes instead of doing the work. The usage-limit
  # wording is borrowed from the service that owns it, because that pattern is
  # anchored tightly enough ("hit your … limit … resets") that only a refusal
  # matches it.
  #
  # The logged-out wording is spelled out here rather than borrowed from
  # AuthRecoveryService::AUTH_RECOVERABLE_ERROR_PATTERN. That constant answers a
  # different question — "should this session rotate accounts?" — and is
  # deliberately a wide net, wide enough to match ordinary English a session
  # writes ABOUT auth work ("fixed the bug where the access token expired").
  # Importing it here would discard those summaries as refusals. Two short
  # patterns that cannot appear in a real summary are the right size for this
  # question.
  REFUSAL_PATTERNS = [
    ApiErrorRetryService::ACCOUNT_QUOTA_LIMIT_PATTERN,
    /not logged in/i,
    /please run\s*\/login/i
  ].freeze

  module_function

  # The storable blurb in this text, or nil when there is not one.
  #
  # Strips the wrapper a model sometimes puts around a "reply with only X"
  # answer (a fenced block), refuses a refusal, then truncates.
  #
  # @param text [String, nil] raw answer text
  # @return [String, nil]
  def clean(text)
    return nil if text.blank?

    cleaned = text.strip
    cleaned = cleaned.sub(/\A```[a-z]*\n/i, "").sub(/\n?```\z/, "").strip
    return nil if cleaned.blank?
    return nil if refusal?(cleaned)

    cleaned.truncate(MAX_SUMMARY_CHARS)
  end

  # Whether this is the runtime's refusal rather than an answer.
  #
  # Squished before it is measured or matched. A refusal can arrive wrapped over
  # two lines, or assembled from two content parts joined with a blank line — and
  # the patterns are single-line (`.` does not cross a newline), so testing the
  # raw text would let exactly those through.
  def refusal?(text)
    probe = text.to_s.squish
    return false if probe.blank?
    return false if probe.length > MAX_REFUSAL_CHARS

    REFUSAL_PATTERNS.any? { |pattern| probe.match?(pattern) }
  end
end
