# frozen_string_literal: true

# Turns a raised exception (or a raw log blob) into the bounded excerpt that
# rides along with an AlertService alert.
#
# Why this exists: alerts used to carry only hand-written prose — "Condition 42
# on trigger 'x' failed: <e.message>" — so the one thing a human needs to
# diagnose from Slack (what actually blew up, and where in our code) was the one
# thing missing. The backtrace was always right there at the rescue site.
#
# Two decisions carry most of the value:
#
# 1. *Which* frames. A head-only cut of a Rails backtrace is nearly all vendored
#    middleware and gem frames — true, and useless. This keeps the topmost frames
#    (where the raise happened) plus the first app-owned frames (which of our
#    code did it), and states how many frames it dropped in between.
# 2. *Explicit* truncation. Every cut is marked, so a reader never mistakes an
#    elided snippet for a complete one.
#
# Snippets never influence deduplication — see AlertService#raise_alert.
class AlertSnippet
  # Per-alert cap. Slack's section-block text limit is 3000 characters and the
  # snippet renders inside a fenced block of its own, so this leaves a wide
  # margin for the fence and for Slack's overall payload budget while still
  # fitting an exception line plus ~10 backtrace frames.
  MAX_CHARS = 1200

  # Tighter cap for snippets folded into an AlertBatcher aggregate, where N
  # occurrences share one 2700-character body.
  MAX_BATCHED_CHARS = 500

  # How many app-owned frames are worth showing; beyond this a backtrace is
  # repeating the same call path through the framework.
  APP_FRAME_LIMIT = 8

  # How many of the topmost (usually vendored) frames to keep. This is where the
  # error was actually raised — `net/http.rb:in 'connect'` says more about an
  # ECONNREFUSED than any of our frames do.
  TOP_FRAME_LIMIT = 2

  # Nested causes are frequently the real story (an adapter error wrapping a
  # connection error). Bounded so a deep cause chain can't crowd out the frames.
  CAUSE_LIMIT = 2
  CAUSE_FRAME_LIMIT = 3

  # Share of the character budget the head keeps when a blob has to be elided;
  # the rest goes to the tail, because the end of a log is often where the
  # failure is.
  HEAD_SHARE = 0.7

  # Headroom reserved for the "… N characters elided …" marker itself.
  MARKER_RESERVE = 48

  REDACTED = "[REDACTED]"

  # Frames from installed gems / the Ruby stdlib. Not "unimportant" — just not
  # the frames a reader of #eng-alerts can act on.
  VENDOR_FRAME_PATTERN = %r{/(?:gems|vendor/bundle|rubygems|ruby/\d)/}

  # Secret shapes that can plausibly appear in a raw log line or an exception
  # message (a failing HTTP request that echoes its Authorization header, a
  # connection string, a shell command in an Errno message).
  REDACTION_RULES = [
    [ /xox[abposre]-[A-Za-z0-9-]{8,}/, REDACTED ],                                  # Slack tokens
    [ /\bgh[pousr]_[A-Za-z0-9]{16,}/, REDACTED ],                                   # GitHub tokens
    [ /\bgithub_pat_[A-Za-z0-9_]{20,}/, REDACTED ],                                 # GitHub fine-grained PATs
    [ /\bsk-ant-[A-Za-z0-9\-_]{16,}/, REDACTED ],                                   # Anthropic API keys
    [ /\bAKIA[0-9A-Z]{16}\b/, REDACTED ],                                           # AWS access key IDs
    [ /\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}/, REDACTED ], # JWTs
    [ /\b(Bearer|Basic)\s+[A-Za-z0-9\-._~+\/]{12,}=*/i, '\1 ' + REDACTED ],         # Authorization headers
    [ %r{(://[^/\s:@]+:)[^/\s@]+@}, '\1' + REDACTED + "@" ],                        # URL userinfo passwords
    [ /((?:api[_-]?key|access[_-]?token|token|secret|password|passwd)["']?\s*[:=]\s*["']?)([^\s"',;)]{6,})/i,
      '\1' + REDACTED ]
  ].freeze

  class << self
    # Build a snippet from whatever the call site has.
    #
    # @param error [Exception, String, nil] a rescued exception (preferred — the
    #   backtrace is the high-signal part) or a raw log/stderr blob.
    # @param max_chars [Integer] hard cap on the returned string.
    # @return [String, nil] the excerpt, or nil when there is nothing to show.
    def build(error, max_chars: MAX_CHARS)
      return nil if error.nil?

      text = error.is_a?(Exception) ? render_exception(error) : error.to_s
      text = redact(text).strip
      return nil if text.empty?

      clamp(text, max_chars)
    end

    # Bound an already-built snippet to a smaller budget, marking the cut.
    # Public because AlertBatcher re-clamps per-occurrence snippets when it folds
    # several of them into one aggregated body.
    def clamp(text, max_chars)
      return text if text.length <= max_chars
      return text[0, max_chars] if max_chars <= MARKER_RESERVE * 2

      budget = max_chars - MARKER_RESERVE
      head = snap_to_line_end(text[0, (budget * HEAD_SHARE).floor])
      tail = snap_to_line_start(text[-(budget - head.length)..] || "")

      dropped = text.length - head.length - tail.length
      "#{head}\n… #{dropped} characters elided …\n#{tail}"
    end

    # Wrap a snippet in a Slack fenced code block. Inner fences are defanged so
    # a backtick run inside the log can't terminate the block early and spill
    # the rest as prose.
    def fenced(text)
      "```\n#{text.to_s.gsub('```', "'''")}\n```"
    end

    # Mask secret-shaped substrings. Exposed for tests and for call sites that
    # assemble their own body.
    def redact(text)
      REDACTION_RULES.reduce(text.to_s) { |acc, (pattern, replacement)| acc.gsub(pattern, replacement) }
    end

    private

    def render_exception(error)
      lines = [ "#{error.class}: #{error.message}" ]
      lines.concat(frame_lines(error.backtrace, app_limit: APP_FRAME_LIMIT, top_limit: TOP_FRAME_LIMIT))
      lines.concat(cause_lines(error))
      lines.join("\n")
    end

    # `Caused by:` chain, bounded. Guarded against a self-referential or cyclic
    # cause (possible when an exception is re-raised inside its own rescue),
    # which would otherwise loop forever.
    def cause_lines(error)
      lines = []
      seen = [ error ]
      cause = error.cause

      CAUSE_LIMIT.times do
        break if cause.nil? || seen.any? { |e| e.equal?(cause) }

        seen << cause
        lines << ""
        lines << "Caused by: #{cause.class}: #{cause.message}"
        lines.concat(frame_lines(cause.backtrace, app_limit: CAUSE_FRAME_LIMIT, top_limit: 1))
        cause = cause.cause
      end

      lines
    end

    # Render the chosen frames in their original order, with an explicit marker
    # wherever frames were skipped.
    def frame_lines(backtrace, app_limit:, top_limit:)
      return [] if backtrace.blank?

      chosen = selected_indexes(backtrace, app_limit, top_limit)
      lines = []
      previous = -1

      chosen.each do |index|
        gap = index - previous - 1
        lines << "  … #{frame_count(gap)} elided …" if gap.positive?
        lines << "  #{relativize(backtrace[index])}"
        previous = index
      end

      trailing = backtrace.length - 1 - previous
      lines << "  … #{frame_count(trailing)} elided …" if trailing.positive?
      lines
    end

    def selected_indexes(backtrace, app_limit, top_limit)
      app = backtrace.each_index.select { |i| app_frame?(backtrace[i]) }.first(app_limit)
      top = (0...backtrace.length).first(top_limit)
      chosen = (app + top).uniq.sort
      # A backtrace with no app-owned frames at all (raised entirely inside a
      # gem, or synthesized in a test) still deserves its top frames.
      chosen.presence || (0...backtrace.length).first(app_limit)
    end

    def app_frame?(frame)
      return false if frame.match?(VENDOR_FRAME_PATTERN)

      frame.start_with?(rails_root_prefix) || !frame.start_with?("/")
    end

    def relativize(frame)
      frame.delete_prefix(rails_root_prefix)
    end

    def rails_root_prefix
      @rails_root_prefix ||= "#{Rails.root}/"
    end

    def frame_count(count)
      "#{count} frame#{'s' unless count == 1}"
    end

    # Trim a partial trailing line so the head ends on a real boundary. Keeps the
    # whole thing when there is no newline to snap to (a single long line).
    def snap_to_line_end(chunk)
      snapped = chunk.sub(/\n[^\n]*\z/, "")
      snapped.presence || chunk
    end

    def snap_to_line_start(chunk)
      snapped = chunk.sub(/\A[^\n]*\n/, "")
      snapped.presence || chunk
    end
  end
end
