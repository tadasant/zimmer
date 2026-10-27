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
  # Hard cap on stored summary text. The prompt asks for three sentences; this is
  # the backstop for a model that answered with an essay, so the panel cannot
  # push the rest of the page off screen.
  MAX_SUMMARY_CHARS = 1200

  # A refusal is one short line. A real answer is up to three sentences carrying
  # markdown links, and is an order of magnitude longer — so length is what keeps the
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

  # The CarPlay-fit trailer both prompts ask for as their last line
  # (SessionStatusSummaryGenerator::CARPLAY_FIT_TRAILER_RULE). Two patterns,
  # because two questions are asked of the last non-blank line. CARPLAY_FIT_LINE
  # is "is this the trailer at all?" — anything that opens with `carplay-fit:`,
  # however the rest came out — and a line that matches it is never stored,
  # since the reader was promised not to see it. CARPLAY_FIT_TRAILER is "what
  # does it say?", lenient on punctuation and on backticks or quotes around the
  # values: a model that wrote `` carplay-fit: `laptop_only`; reason: `credential` ``
  # has still answered. The fit is required; the reason is optional, and an
  # unknown reason is dropped rather than refusing the fit it came with. A line
  # that opens like the trailer but names no fit is stripped and yields no mark.
  CARPLAY_FIT_LINE = /\A[\s`*_>-]*carplay-fit\s*:/i
  CARPLAY_FIT_TRAILER = /\A[\s`*_>-]*carplay-fit\s*:\s*[`"'*_]*(?<fit>carplay_ok|laptop_only)[`"'*_]*\s*(?:[;,·|(]\s*reason\s*:\s*[`"'*_]*(?<reason>[a-z_]+))?/i

  module_function

  # The storable blurb in this text, or nil when there is not one.
  #
  # Strips the wrapper a model sometimes puts around a "reply with only X"
  # answer (a fenced block), drops the CarPlay-fit trailer the prompt asked for
  # (that line is for StatusSummaryAnswer.carplay_fit, never for the reader),
  # refuses a refusal, then truncates.
  #
  # @param text [String, nil] raw answer text
  # @return [String, nil]
  def clean(text)
    return nil if text.blank?

    cleaned = unwrap(text)
    cleaned, _trailer = split_carplay_fit_trailer(cleaned)
    return nil if cleaned.blank?
    return nil if refusal?(cleaned)

    cleaned.truncate(MAX_SUMMARY_CHARS)
  end

  # The CarPlay-fit judgement the answer ends with, or nil when it carries none.
  #
  # @param text [String, nil] raw answer text
  # @return [Hash{Symbol => String}, nil] `{ fit:, reason: }`, reason nil when
  #   absent or not one of SessionCarplayFit::REASONS
  def carplay_fit(text)
    return nil if text.blank?

    _blurb, trailer = split_carplay_fit_trailer(unwrap(text))
    return nil if trailer.nil?

    match = trailer.match(CARPLAY_FIT_TRAILER)
    return nil if match.nil?

    reason = match[:reason]&.downcase
    reason = nil unless SessionCarplayFit::REASONS.include?(reason)
    { fit: match[:fit].downcase, reason: reason }
  end

  # Writes the answer's CarPlay-fit judgement onto the session as an `auto` mark
  # stamped at `line_count` — the line count the blurb itself is stamped with,
  # so the two go stale together. Best-effort, and silent on the two outcomes
  # that are not failures: an answer with no trailer leaves the session as it
  # was, and a standing human, assistant or session mark at the same position
  # keeps its precedence (Sessions::SetCarplayFit says so in its result rather
  # than raising). A mark must never fail a summary that already landed.
  #
  # @param session [Session] the summarized session
  # @param text [String, nil] raw answer text
  # @param line_count [Integer] the transcript line count the blurb was written from
  # @return [Sessions::SetCarplayFit::Result, nil]
  def apply_carplay_fit(session, text, line_count:)
    mark = carplay_fit(text)
    return nil if mark.nil?

    Sessions::SetCarplayFit.call(
      session: session,
      fit: mark[:fit],
      reason: mark[:reason],
      source: SessionCarplayFit::SOURCE_AUTO,
      line_count: line_count
    )
  rescue StandardError => e
    Rails.logger.error("[StatusSummaryAnswer] Could not apply the CarPlay-fit trailer on session #{session&.id}: #{e.class}: #{e.message}")
    nil
  end

  # A fenced block a model sometimes wraps a "reply with only X" answer in.
  def unwrap(text)
    text.strip.sub(/\A```[a-z]*\n/i, "").sub(/\n?```\z/, "").strip
  end

  # The text with its trailer line removed, and the trailer line itself (nil
  # when the last non-blank line does not open like one).
  def split_carplay_fit_trailer(text)
    lines = text.to_s.rstrip.lines.map(&:rstrip)
    last = lines.rindex { |line| !line.strip.empty? }
    return [ text, nil ] if last.nil?
    return [ text, nil ] unless lines[last].match?(CARPLAY_FIT_LINE)

    trailer = lines[last]
    [ lines[0...last].join("\n").rstrip, trailer ]
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
