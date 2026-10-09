# frozen_string_literal: true

module Mcp
  # A bounded, navigable piece of one session's transcript, rendered for a remote
  # reader — the `get_session` MCP tool's `include_transcript` path.
  #
  # WHY THIS EXISTS
  #
  # A caller on the far side of MCP has no route to a transcript but this one (the
  # file-path hint points at a disk it cannot reach), and an ordinary session's
  # whole transcript runs to ~56k tokens — past a client's tool-result limit, which
  # refuses the result outright. So the transcript is only ever returned as a
  # window of events (head, tail, or an index range) under a character cap that
  # ALWAYS applies — a default one when the caller names none — with an optional
  # conversation-only rendering that drops tool traffic down to one-line stubs.
  #
  # THE UNIT IS ONE STORED JSONL LINE, CALLED AN "EVENT"
  #
  # Indices are 0-based line numbers in the stored transcript. The store is
  # append-only, so an index keeps meaning the same event as the session grows,
  # which is what lets a caller page: every response states the total, the indices
  # it returned, and the exact parameters that fetch what it did not. The one
  # exception is a rewrite (`ChunkedTranscript#replace_transcript_chunks`: a
  # carryover re-attachment, a recovery merge, a fork's truncation), after which
  # an index saved earlier can name a different event.
  #
  # The walk parses only what it renders, and stops when the budget is spent —
  # except that events with nothing to show in the conversation rendering cost
  # nothing, so a conversation-only tail of a session that is almost all tool
  # traffic can parse most of the transcript before its budget fills.
  #
  # NOTHING IS CUT SILENTLY
  #
  # The cap stops the walk at an event boundary and says where, with the range it
  # left out and the call that returns it. When even the first event in the walk is
  # over the budget it is cut mid-event rather than skipped — so a caller always
  # makes progress — and that cut is marked in place too. The same rule
  # `get_session`'s other summaries follow (#652): a cut is only acceptable if the
  # caller can see it happened.
  class TranscriptSlice
    class InvalidRequest < ArgumentError; end

    # ~10k tokens at ~4 characters a token: room for the rest of the `get_session`
    # dump and the caller's own context, well inside a 45k-token tool-result limit.
    DEFAULT_MAX_CHARS = 40_000
    MIN_MAX_CHARS = 1_000
    # An explicit request can go higher, but not unboundedly: past this a single
    # result is a context-window hazard whatever the client's own limit is.
    MAX_MAX_CHARS = 400_000

    # How much of a tool call's arguments the conversation rendering keeps.
    STUB_ARGUMENT_CHARS = 120

    FORMATS = %w[raw text conversation].freeze

    FORMAT_LABELS = {
      "raw" => "raw JSONL, one event per line",
      "text" => "plain text, each event prefixed with its [#index]",
      "conversation" => "conversation only — human and assistant text, each tool call collapsed to one line, tool output and thinking omitted"
    }.freeze

    # @param session [Session]
    # @param format [String] one of FORMATS
    # @param head [Integer, nil] the first N events
    # @param tail [Integer, nil] the last N events
    # @param from [Integer, nil] first index of a range (inclusive)
    # @param to [Integer, nil] end of a range (exclusive)
    # @param max_chars [Integer, nil] the character cap; DEFAULT_MAX_CHARS when nil
    def initialize(session, format: "raw", head: nil, tail: nil, from: nil, to: nil, max_chars: nil)
      raise InvalidRequest, "Unknown transcript format #{format.inspect}" unless FORMATS.include?(format)

      @session = session
      @format = format
      @head = count_param("transcript_head", head)
      @tail = count_param("transcript_tail", tail)
      @from = index_param("transcript_from", from)
      @to = index_param("transcript_to", to)
      @max_chars = max_chars.nil? ? DEFAULT_MAX_CHARS : integer_param("transcript_max_chars", max_chars).clamp(MIN_MAX_CHARS, MAX_MAX_CHARS)
      @max_chars_requested = max_chars.nil? ? nil : integer_param("transcript_max_chars", max_chars)

      validate_selection!
    end

    def total
      @total ||= @session.transcript_line_count
    end

    # The markdown section `get_session` appends. Always begins with a heading and
    # the navigation bullets, then the events in chronological order in a fence.
    def render
      lo, hi, backward = requested_range
      pieces, covered_lo, covered_hi, cut_event = walk(lo, hi, backward)

      lines = [ "", "### Transcript" ]
      lines.concat(summary_lines(lo, hi, pieces, covered_lo, covered_hi, backward, cut_event))
      return lines.join("\n") if pieces.empty?

      body = pieces.sort_by(&:first).map(&:last)
      body.unshift(gap_marker(lo, covered_lo)) if backward && covered_lo > lo
      body.push(gap_marker(covered_hi, hi)) if !backward && covered_hi < hi

      lines << "```"
      lines.concat(body)
      lines << "```"
      lines.join("\n")
    end

    private

    # [lo, hi, backward]: the half-open range the caller asked for, clamped to the
    # transcript, and which end the budget is spent from. A tail — and the default,
    # no selector at all — keeps the newest events, because "what is it doing now"
    # is the question a remote reader almost always came with.
    def requested_range
      if @head
        [ 0, [ @head, total ].min, false ]
      elsif @tail
        [ [ total - @tail, 0 ].max, total, true ]
      elsif @from || @to
        lo = [ @from || 0, total ].min
        [ lo, [ @to || total, total ].min.clamp(lo, total), false ]
      else
        [ 0, total, true ]
      end
    end

    # Walks the range from the end the budget is spent from, and stops at the
    # first event that does not fit. Returns the rendered pieces, the contiguous
    # range [covered_lo, covered_hi) the walk got through (events the
    # conversation rendering drops count as covered), and the index of an event
    # that was itself cut mid-way, if any.
    def walk(lo, hi, backward)
      budget = @max_chars
      pieces = []
      covered_lo = backward ? hi : lo
      covered_hi = backward ? hi : lo
      cut_event = nil

      @session.each_transcript_line(lo, hi, reverse: backward) do |index, line|
        text = render_event(index, line)
        unless text.empty?
          cost = text.length + 1
          if cost > budget
            break unless pieces.empty?

            text = cut_mid_event(index, text, budget)
            cut_event = index
            cost = budget
          end
          pieces << [ index, text ]
          budget -= cost
        end

        backward ? covered_lo = index : covered_hi = index + 1
        break if cut_event
      end

      [ pieces, covered_lo, covered_hi, cut_event ]
    end

    def render_event(index, line)
      case @format
      when "raw" then line.chomp
      when "text" then text_event(index, line)
      when "conversation" then conversation_event(index, line)
      end
    end

    def text_event(index, line)
      rendered = source.parse_events(line).map do |event|
        TranscriptTextRenderer.entry_lines(event).join("\n").rstrip
      end.reject(&:empty?)
      return "" if rendered.empty?

      "[##{index}] #{rendered.join("\n")}"
    end

    # Normalizes through the session's runtime so the rendering means the same
    # thing for Claude Code, Codex and Pi: user and assistant text in full, a tool
    # call as one line, and nothing else.
    def conversation_event(index, line)
      source.parse_events(line).flat_map do |raw|
        normalizer.normalize(raw, session: @session, transcript_index: index)
      end.filter_map { |event| conversation_line(index, event) }.join("\n")
    end

    def conversation_line(index, event)
      types = OpenTranscript::Types
      case event[:type]
      when types::USER_MESSAGE, types::ASSISTANT_MESSAGE
        return nil if OpenTranscript.blank_message?(event)

        speaker = event[:type] == types::USER_MESSAGE ? "User" : "Assistant"
        "[##{index}] #{speaker}: #{TranscriptTextRenderer.content_text(event[:content]).strip}"
      when types::TOOL_CALL
        "[##{index}] [tool call: #{event[:tool_name] || 'unknown'}] #{stub_arguments(event[:arguments])}".rstrip
      when types::SUBAGENT_SPAWN
        "[##{index}] [subagent: #{event[:subagent_type] || 'unknown'}] #{event[:description].to_s.squish.truncate(STUB_ARGUMENT_CHARS)}".rstrip
      when types::COMPACTION
        "[##{index}] [context compacted]"
      end
    end

    def stub_arguments(arguments)
      text = arguments.is_a?(String) ? arguments : JSON.generate(arguments)
      text.squish.truncate(STUB_ARGUMENT_CHARS)
    rescue JSON::GeneratorError, Encoding::UndefinedConversionError
      arguments.to_s.squish.truncate(STUB_ARGUMENT_CHARS)
    end

    def source
      @source ||= TranscriptRuntime.source_for(@session)
    end

    def normalizer
      @normalizer ||= TranscriptRuntime.normalizer_for(@session)
    end

    def cut_mid_event(index, text, budget)
      marker = "\n[… event ##{index} cut: showing #{TextBudget.delimited([ budget - 200, 0 ].max)} of " \
               "#{TextBudget.delimited(text.length)} characters. Raise transcript_max_chars " \
               "(up to #{TextBudget.delimited(MAX_MAX_CHARS)}) to read more of it …]"
      text[0, [ budget - 200, 0 ].max] + marker
    end

    def gap_marker(gap_lo, gap_hi)
      "[… #{range_label(gap_lo, gap_hi)} not shown (character cap reached). " \
        "Fetch them with #{range_params(gap_lo, gap_hi)} …]"
    end

    def summary_lines(lo, hi, pieces, covered_lo, covered_hi, backward, cut_event)
      lines = [
        "- **Events:** #{TextBudget.delimited(total)} in total. Indices are 0-based, one per stored JSONL line, " \
        "and stable as the transcript grows (unless Zimmer rewrites it in a recovery merge or carryover)."
      ]

      if lo >= hi
        lines << "- **Returned:** nothing — the requested range is empty#{" (the transcript has no events)" if total.zero?}."
        return lines
      end

      lines << "- **Requested:** #{range_label(lo, hi)} (#{selection_label})."
      lines << "- **Returned:** #{returned_label(pieces, covered_lo, covered_hi)} as #{FORMAT_LABELS.fetch(@format)}."
      lines << cap_line

      cut_lo, cut_hi = backward ? [ lo, covered_lo ] : [ covered_hi, hi ]
      if cut_lo < cut_hi
        lines << "- **Truncated:** yes — the #{TextBudget.delimited(@max_chars)}-character cap was reached; " \
                 "#{range_label(cut_lo, cut_hi)} of the requested range #{cut_hi - cut_lo == 1 ? "was" : "were"} not returned. " \
                 "Fetch them with #{range_params(cut_lo, cut_hi)}, or raise `transcript_max_chars`."
      end
      if cut_event
        lines << "- **Cut mid-event:** event ##{cut_event} alone is larger than the cap and is shown only in part; " \
                 "its marker says how much."
      end
      lines << "- **Not truncated:** every event in the requested range is returned." if cut_lo >= cut_hi && cut_event.nil?

      outside = []
      outside << "earlier: #{range_label(0, lo)} (#{range_params(0, lo)})" if lo.positive?
      outside << "later: #{range_label(hi, total)} (#{range_params(hi, total)})" if hi < total
      lines << "- **Outside the requested range:** #{outside.join('; ')}." if outside.any?

      lines
    end

    def selection_label
      if @head then "transcript_head: #{@head}"
      elsif @tail then "transcript_tail: #{@tail}"
      elsif @from || @to then [ ("transcript_from: #{@from}" if @from), ("transcript_to: #{@to}" if @to) ].compact.join(", ")
      else "no selector given, so the newest events that fit the cap"
      end
    end

    def returned_label(pieces, covered_lo, covered_hi)
      return "no events" if covered_lo >= covered_hi

      label = range_label(covered_lo, covered_hi)
      hidden = (covered_hi - covered_lo) - pieces.size
      label += " (#{TextBudget.delimited(hidden)} of them #{hidden == 1 ? 'has' : 'have'} nothing to show in this format and #{hidden == 1 ? 'is' : 'are'} omitted)" if hidden.positive?
      label
    end

    def cap_line
      line = "- **Character cap:** #{TextBudget.delimited(@max_chars)} (≈#{TextBudget.delimited(@max_chars / 4)} tokens)"
      if @max_chars_requested.nil?
        line + " — the default; pass `transcript_max_chars` (#{TextBudget.delimited(MIN_MAX_CHARS)}–#{TextBudget.delimited(MAX_MAX_CHARS)}) to change it."
      elsif @max_chars_requested != @max_chars
        line + " — clamped from the requested #{TextBudget.delimited(@max_chars_requested)}."
      else
        line + "."
      end
    end

    # Inclusive, human-readable: "events #120–#169", or "event #120" for one.
    def range_label(lo, hi)
      hi - lo == 1 ? "event ##{lo}" : "events ##{lo}–##{hi - 1}"
    end

    def range_params(lo, hi)
      "`transcript_from: #{lo}, transcript_to: #{hi}`"
    end

    def validate_selection!
      groups = [ @head, @tail, (@from || @to) ].compact
      if groups.size > 1
        raise InvalidRequest, "Pass at most one of transcript_head, transcript_tail, or a transcript_from/transcript_to range"
      end
      if @from && @to && @to <= @from
        raise InvalidRequest, "transcript_to (#{@to}) must be greater than transcript_from (#{@from}); transcript_to is exclusive"
      end
    end

    def count_param(name, value)
      return nil if value.nil?

      integer_param(name, value).tap do |n|
        raise InvalidRequest, "#{name} must be at least 1" if n < 1
      end
    end

    def index_param(name, value)
      return nil if value.nil?

      integer_param(name, value).tap do |n|
        raise InvalidRequest, "#{name} must be 0 or greater" if n.negative?
      end
    end

    def integer_param(name, value)
      raise InvalidRequest, "#{name} must be an integer, got #{value.inspect}" if value.is_a?(Float) && value != value.floor

      Integer(value)
    rescue ArgumentError, TypeError
      raise InvalidRequest, "#{name} must be an integer, got #{value.inspect}"
    end
  end
end
