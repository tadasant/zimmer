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
  # OR THE UNIT IS ONE MESSAGE: `messages: N`
  #
  # A conversation-only `tail: N` still counts events, and most events in a
  # working session are tool traffic — so a tail of 20 taken after a burst of
  # tool calls can come back with one assistant line or none. `messages: N`
  # (the `transcript_last_messages` parameter) counts what a reader grounding a
  # decision actually wants: the last N user and assistant text messages,
  # however many events of tool traffic sit between them. Each run of tool
  # calls between two messages is folded into one line that names the tools
  # and the events it spans, so the reader still sees that work happened and
  # where to page for it. The walk goes back through the whole transcript if it
  # has to; it stops at N messages or at the character cap, whichever is first.
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

    # How many messages `messages: N` may ask for. Past this a caller wants a
    # range, not a "last few" read.
    MAX_MESSAGES = 200

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
    # @param messages [Integer, nil] the last N user/assistant messages; forces the conversation format
    def initialize(session, format: "raw", head: nil, tail: nil, from: nil, to: nil, max_chars: nil, messages: nil)
      raise InvalidRequest, "Unknown transcript format #{format.inspect}" unless FORMATS.include?(format)

      @session = session
      @messages = count_param("transcript_last_messages", messages)
      if @messages && @messages > MAX_MESSAGES
        raise InvalidRequest, "transcript_last_messages must be at most #{MAX_MESSAGES}, got #{@messages}"
      end
      @format = @messages ? "conversation" : format
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
      return render_last_messages if @messages

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

    # The `messages: N` rendering: walk back from the newest event, keep user and
    # assistant text (and compaction markers, which explain a gap in memory), and
    # fold each run of tool calls between them into one line. A stored line is
    # always read to its end, so a window boundary never falls inside one; the
    # walk stops at N messages, the cap, or MAX_SCAN_EVENTS. Returns the section
    # in the same shape as #render.
    def render_last_messages
      walk = MessageWalk.new
      walk.budget = @max_chars
      walk.covered_lo = total
      gap_hi = total - 1 # the newest event not yet accounted to a message

      @session.each_transcript_line(0, total, reverse: true) do |index, line|
        if total - index > MAX_SCAN_EVENTS
          walk.stop = :scan
          break
        end

        source.parse_events(line).reverse_each do |raw|
          compact_summary = raw.is_a?(Hash) && raw["isCompactSummary"]
          events = normalizer.normalize(raw, session: @session, transcript_index: index)

          # Within one stored line, newest last — walk it newest first.
          events.reverse_each do |event|
            types = OpenTranscript::Types
            case event[:type]
            when types::TOOL_CALL
              walk.pending ||= { lo: index, hi: [ gap_hi, index ].max, names: Hash.new(0) }
              walk.pending[:lo] = index
              walk.pending[:names][event[:tool_name] || "unknown"] += 1
            when types::USER_MESSAGE, types::ASSISTANT_MESSAGE, types::COMPACTION
              # Past N, the rest of this stored line is still read, so the
              # window never ends inside a line; any other stop ends the walk.
              next if walk.stop && walk.stop != :found

              # The summary Claude Code writes after a compaction wears a user role;
              # it is neither a human's words nor a message worth spending N on.
              text = compact_summary ? "[##{index}] [context compacted — the summary it left is omitted]" : conversation_line(index, event)
              next if text.nil?

              keep_message(walk, index, text, counts: !compact_summary && event[:type] != types::COMPACTION)
              gap_hi = index - 1
            end
          end
        end

        # A capped or cut line was only partly shown, so it stays inside the
        # "earlier" range the section points at.
        break if %i[capped cut].include?(walk.stop)

        walk.covered_lo = index
        break if walk.stop
      end

      # A run of tool calls older than the oldest message kept: shown when the
      # walk read through to the start of the transcript.
      flush_tool_run(walk) if walk.stop.nil?

      last_messages_section(walk)
    end

    # The walk's state, shared between #render_last_messages and its helpers.
    # `stop` is nil while walking, then :found (N messages), :cut (one message cut
    # mid-way), :capped (the cap) or :scan (MAX_SCAN_EVENTS).
    MessageWalk = Struct.new(:budget, :entries, :pending, :found, :covered_lo, :lowest_shown, :stop, :cut_event) do
      def initialize(*)
        super
        self.entries ||= []
        self.found ||= 0
      end
    end

    def keep_message(walk, index, text, counts:)
      flush_tool_run(walk)
      return if walk.stop == :capped

      cost = text.length + 1
      if cost > walk.budget
        # Cut rather than skip the newest message, so a caller always gets one.
        unless walk.found.zero?
          walk.stop = :capped
          return
        end

        text = cut_mid_event(index, text, walk.budget)
        walk.cut_event = index
        walk.stop = :cut
        cost = walk.budget
      end

      walk.entries << text
      walk.budget -= cost
      walk.lowest_shown = index
      walk.found += 1 if counts || walk.stop == :cut
      walk.stop = :found if walk.stop.nil? && walk.found >= @messages
    end

    def flush_tool_run(walk)
      run = walk.pending
      return if run.nil?

      walk.pending = nil
      line = tool_run_line(run)
      if line.length + 1 > walk.budget
        walk.stop = :capped
        return
      end
      walk.entries << line
      walk.budget -= line.length + 1
    end

    # How many tools a folded run names before it summarises the rest.
    MAX_TOOL_NAMES = 8

    # How far back the walk reads looking for N messages. Tool traffic costs
    # nothing against the character cap, so without this a session that is
    # almost all tool calls would be parsed end to end on every call.
    MAX_SCAN_EVENTS = 20_000

    def tool_run_line(run)
      calls = run[:names].values.sum
      names = run[:names].sort_by { |name, n| [ -n, name ] }.map { |name, n| n > 1 ? "#{name} ×#{n}" : name }
      names = names.first(MAX_TOOL_NAMES) + [ "+#{names.size - MAX_TOOL_NAMES} more" ] if names.size > MAX_TOOL_NAMES
      span = run[:lo] == run[:hi] ? "event ##{run[:lo]}" : "events ##{run[:lo]}–##{run[:hi]}"
      "[… #{calls} tool call#{'s' unless calls == 1} (#{names.join(', ')}) in #{span} …]"
    end

    def last_messages_section(walk)
      found = walk.found
      lines = [
        "", "### Transcript",
        "- **Events:** #{TextBudget.delimited(total)} in total. Indices are 0-based, one per stored JSONL line, " \
        "and stable as the transcript grows (unless Zimmer rewrites it in a recovery merge or carryover)."
      ]
      plural = ->(n) { "#{n} message#{'s' unless n == 1}" }

      if walk.entries.empty? && walk.stop != :capped && walk.stop != :scan
        lines << "- **Returned:** nothing — #{total.zero? ? 'the transcript has no events' : 'the transcript holds no user or assistant messages'}."
        return lines.join("\n")
      end

      window_lo = [ walk.covered_lo, walk.lowest_shown || walk.covered_lo ].min
      lines << "- **Requested:** the last #{plural.(@messages)} (transcript_last_messages: #{@messages})."
      lines << "- **Returned:** #{plural.(found)} from #{window_lo < total ? range_label(window_lo, total) : 'no events'} " \
               "as conversation only — human and assistant text, each run of tool calls between two messages folded into " \
               "one `[… N tool calls …]` line, tool output and thinking omitted."
      lines << cap_line

      case walk.stop
      when :capped
        lines << "- **Truncated:** yes — the #{TextBudget.delimited(@max_chars)}-character cap was reached after #{found} of #{@messages} messages. " \
                 "Raise `transcript_max_chars`, or read the earlier part with #{range_params(0, walk.covered_lo)} and `transcript_conversation_only: true`."
      when :scan
        lines << "- **Truncated:** yes — the walk stopped after reading the newest #{TextBudget.delimited(MAX_SCAN_EVENTS)} events with #{found} of #{@messages} messages found. " \
                 "Read further back with #{range_params(0, walk.covered_lo)} and `transcript_conversation_only: true`."
      when :cut
        lines << "- **Cut mid-event:** event ##{walk.cut_event} alone is larger than the cap and is shown only in part; its marker says how much. " \
                 "The walk stopped there, at 1 of #{@messages} messages."
      when nil
        lines << "- **Not truncated:** the whole transcript holds only #{plural.(found)}, and all of them are returned."
      end
      if walk.covered_lo.positive?
        lines << "- **Outside the returned window:** earlier: #{range_label(0, walk.covered_lo)} (#{range_params(0, walk.covered_lo)})."
      end
      return lines.join("\n") if walk.entries.empty?

      lines << "```"
      lines.concat(walk.entries.reverse)
      lines << "```"
      lines.join("\n")
    end

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
      groups = [ @head, @tail, (@from || @to), @messages ].compact
      if groups.size > 1
        raise InvalidRequest, "Pass at most one of transcript_head, transcript_tail, transcript_last_messages, or a transcript_from/transcript_to range"
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
