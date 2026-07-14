# Extracts the actionable error line(s) from a captured failure message so the UI
# can surface them ABOVE the raw output.
#
# AIR (and other CLIs) routinely prefix real errors with long, non-fatal
# deprecation warnings — e.g. a v0.13.0 "inline plugin bodies are deprecated /
# will be removed in a future release" warning — which pushes the actionable
# error far down the stderr. A user reading a failed session then sees only the
# warning and cannot triage the true cause. Preserving the full `air prepare`
# output is necessary but not sufficient, because the warning still reads first.
#
# The full message is always preserved and rendered separately. These highlights
# are an ADDITIONAL, prominent callout, never a replacement — so a heuristic miss
# can never hide information: worst case the callout is absent and the user reads
# the full block exactly as before.
module ExceptionMessageHighlighter
  # Lines that are non-actionable noise: deprecation / warning chatter. Matched
  # only when the warning token leads the line (`warning:`, `[warn]`, `npm warn`,
  # a ⚠ glyph) or the line is unmistakably a deprecation notice anywhere in it.
  WARNING_LINE = /\A\s*(?:\[?warn(?:ing)?\]?\b|⚠|npm\s+warn\b)/i
  DEPRECATION = /deprecat|will be removed|DeprecationWarning|--trace-deprecation/i

  # Lines that name the actual failure — an error/fatal token leading the line,
  # or a strong error signature anywhere in it.
  ERROR_LINE = /\A\s*(?:error\b|err!|fatal\b|✖|✗|panic\b)|(?:\bError:|\bfailed\b|could not resolve|not found|unresolved|cannot\b)/i

  # A warning clause embedded *inside* an otherwise-actionable line. AIR wraps its
  # stderr as "AIR prepare failed (exit N): <first stderr line>", so when that
  # first stderr line is a `warning:` the whole composite line reads as an error
  # (it contains "failed") yet trails into warning text. We trim that trailing
  # warning clause off callout lines so the "Actionable Error" box never shows
  # warning prose. The `warning:` colon form is required so an error that merely
  # mentions the word "warning" (e.g. "Error: the warning subsystem failed") is
  # left intact.
  EMBEDDED_WARNING = /\s+(?:warning:|⚠|npm\s+warn\b).*\z/i

  # Upper bound on the highlight callout — a handful of error lines, never the
  # whole transcript. The full message is shown separately, so this only bounds
  # the summary.
  MAX_HIGHLIGHT_CHARS = 2_000

  module_function

  # True for lines that are pure warning/deprecation noise.
  def warning_line?(line)
    return true if WARNING_LINE.match?(line)

    # A deprecation notice is noise unless the same line also carries a strong
    # error signature (rare, but never let a deprecation string suppress a real
    # error line).
    DEPRECATION.match?(line) && !strong_error_line?(line)
  end

  # True for lines that name the actual failure and are not warning noise.
  def error_line?(line)
    return false if warning_line?(line)

    ERROR_LINE.match?(line)
  end

  # A line whose error signature is strong enough to override a co-located
  # deprecation token (e.g. "Error: ... is deprecated and now fails").
  def strong_error_line?(line)
    /\A\s*(?:error\b|fatal\b|✖|✗|panic\b)|\bError:/i.match?(line)
  end

  # Trim a trailing embedded warning clause (see EMBEDDED_WARNING) and any
  # leftover separator punctuation so the callout shows only the error part.
  def strip_embedded_warning(line)
    line.sub(EMBEDDED_WARNING, "").sub(/[\s:\-–—]+\z/, "")
  end

  # Returns a newline-joined string of the actionable error lines, but ONLY when
  # the message mixes warnings and errors — the ambiguous case the user must
  # disambiguate. When there are no warnings (nothing crowding the error) or no
  # error lines at all, returns nil and the caller renders just the full message.
  #
  # @param message [String, nil] the full captured failure/exception message
  # @return [String, nil] prominent error highlights, or nil when not applicable
  def highlights(message)
    return nil if message.blank?

    lines = message.to_s.split("\n")
    error_lines = lines.select { |line| error_line?(line) }
    return nil if error_lines.empty?

    # Only surface a separate callout when warnings are actually present to crowd
    # out the error. A clean single-error message needs no disambiguation.
    return nil unless lines.any? { |line| warning_line?(line) }

    error_lines
      .map { |line| strip_embedded_warning(line.strip) }
      .reject(&:blank?)
      .uniq
      .join("\n")
      .truncate(MAX_HIGHLIGHT_CHARS)
  end
end
