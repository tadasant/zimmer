# frozen_string_literal: true

module CycleTimes
  # One session's lifetime, cut into categorized segments that tile it exactly.
  #
  # Inputs are what Zimmer recorded, nothing inferred from prose:
  #
  #   * the timeline's state changes (StateLog) — when a worker took a turn,
  #     when the session paused, slept, was queued, held or parked;
  #   * the transcript's timestamped events (TranscriptEvents) — prompts,
  #     assistant output, tool calls and their results;
  #   * the windows during which this session's children were alive.
  #
  # The span runs from `created_at` to the archive. It is split at every state
  # change into intervals, and each interval is cut one of two ways:
  #
  # RUNNING (a worker had the turn) — by transcript events:
  #   - worker start → first event                         turn_startup
  #   - previous event → an assistant-side event            inference
  #     (AssistantMessage, Thinking, ToolCall, Compaction, Error, SystemEvent)
  #   - tool call → its result                              ToolClassifier's category
  #     Parallel calls: each stretch between results is charged to the call
  #     whose result closes it.
  #   - previous event → a mid-turn user message            unattributed
  #   - last event → the turn's end                         unattributed (wind-down),
  #     or the open tool's category if one never returned
  #
  # NOT RUNNING — by why it was not:
  #   - queued for a worker                                 wait_worker_queue
  #   - after a spot-hold / quota-park line, until the next turn   wait_spot_hold / wait_quota_park
  #   - asleep                                              the wake it armed (WaitClassifier),
  #                                                         wait_sleep if none is found —
  #                                                         but only until that wake was due:
  #                                                         asleep OVERDUE_GRACE past it is
  #                                                         unattributed from the due time on
  #   - needs_input, while a child is alive                 wait_child
  #   - needs_input, otherwise, holding a recorded PR       wait_merge_gate
  #   - needs_input, otherwise, until the archive           wait_human (parked on the action
  #                                                         queue until something closed it)
  #   - needs_input, otherwise                              unattributed
  #   - an MCP elicitation                                  wait_human
  #   - failed (and later revived)                          unattributed
  #
  # The output tiles the span with no gaps and no overlaps, so a lane's
  # category totals sum to its wall-clock by construction.
  class LaneBuilder
    Segment = Data.define(:start, :finish, :category, :detail) do
      def seconds = finish - start
    end

    # An assistant event this long after the last tool call, with a call still
    # open, means the model is generating again: the open call's result was
    # never recorded (an interrupt, a killed process). Calls emitted together
    # in one message land milliseconds apart and stay open.
    ORPHAN_AFTER = 1.0

    # The most segments a lane STORES (see .for_display), so one 4,000-tool-call
    # session does not make a 4 MB row. Totals are computed before this cut.
    MAX_SEGMENTS = 1_500

    # How late a wake may fire and still be the wake the session slept on. A
    # trigger fires within a minute or two of its time; a deploy can hold it a
    # few more. Past this, the session is asleep on a wake that did not fire,
    # and that is not what the wake's prompt was waiting for.
    OVERDUE_GRACE = 15.minutes

    # A sleep that outlived its scheduled wake by more than OVERDUE_GRACE: due
    # when the wake should have fired, resumed when something else woke it.
    MissedWake = Data.define(:due, :resumed) do
      def seconds = resumed - due
    end

    # @return [Array<MissedWake>] filled in by #build
    attr_reader :missed_wakes

    # @param span_start [Time] the session's created_at
    # @param span_end [Time] when it was archived
    # @param changes [Array<StateLog::Change>]
    # @param events [Array<TranscriptEvents::Event>]
    # @param child_windows [Array<Array(Time, Time)>] when each child was alive
    # @param holds_pr [Boolean] whether the session recorded a PR it opened
    def initialize(span_start:, span_end:, changes:, events:, child_windows: [], holds_pr: false)
      @span_start = span_start
      @span_end = [ span_end, span_start ].max
      @changes = changes.select { |c| c.at > span_start && c.at < @span_end }.sort_by(&:at)
      @events = events.sort_by(&:at)
      @child_windows = child_windows
      @holds_pr = holds_pr
    end

    # @return [Array<Segment>]
    def build
      @segments = []
      @missed_wakes = []
      @event_index = 0
      @last_wake = nil
      @pending = {}

      intervals.each do |state, from, to|
        if %i[running resumed].include?(state)
          build_running(from, to, resumed: state == :resumed)
        else
          consume_events_until(to)
          build_waiting(state, from, to)
        end
      end

      compact(@segments)
    end

    private

    # [state, from, to] triples tiling the span. A session starts queued: it was
    # created and has not yet been handed to a worker.
    #
    # A spot-hold or quota-park line is an OVERLAY, not a state: the session is
    # still queued or asleep, but held or parked rather than idle. It colors
    # every queued or asleep interval after it until the next turn starts.
    def intervals
      result = []
      state = :queued
      overlay = nil
      from = @span_start

      @changes.each do |change|
        result << [ effective(state, overlay), from, change.at ] if change.at > from
        from = change.at

        if %i[spot_hold quota_park].include?(change.kind)
          overlay = change.kind
        else
          state = change.kind
          overlay = nil if %i[running resumed].include?(state)
        end
      end

      result << [ effective(state, overlay), from, @span_end ] if @span_end > from
      result
    end

    def effective(state, overlay)
      overlay && %i[queued sleeping].include?(state) ? overlay : state
    end

    # --- Running -----------------------------------------------------------

    # +resumed+: the turn picks up where an MCP elicitation paused it — the
    # same process, so the tool call that asked is still open and there is no
    # startup to charge.
    def build_running(from, to, resumed: false)
      @last_wake = nil unless resumed
      @pending = {} unless resumed
      pending = @pending # tool_call_id => ToolClassifier::Result, in call order
      cursor = from
      first = !resumed
      last_call_at = nil
      result_since_call = false

      while (event = @events[@event_index]) && event.at <= to
        @event_index += 1
        at = event.at.clamp(cursor, to)

        case event.type
        when OpenTranscript::Types::TOOL_RESULT
          result = pending.delete(event.tool_call_id) ||
                   ToolClassifier::Result.new("local_io", "tool result without a recorded call")
          add(cursor, at, first ? "turn_startup" : result.category, first ? "until the first transcript event" : result.detail)
          result_since_call = true
        when OpenTranscript::Types::USER_MESSAGE
          add(cursor, at, first ? "turn_startup" : "unattributed", first ? "until the first transcript event" : "before a mid-turn message")
        when OpenTranscript::Types::COMPACTION
          add(cursor, at, "inference", "context compaction")
        when OpenTranscript::Types::ERROR
          add(cursor, at, "inference", "API error / retry")
        else
          if first
            add(cursor, at, "turn_startup", "until the first transcript event")
          elsif pending.any? && last_call_at && at - last_call_at >= ORPHAN_AFTER
            # The model is generating again, so the open calls are over. Until
            # the last result we saw, the gap was generation; with no result at
            # all since the calls, it was the open call.
            open = pending.values.first
            if result_since_call
              add(cursor, at, "inference", inference_detail(event))
            else
              add(cursor, at, open.category, "#{open.detail} (no result recorded)")
            end
            pending.clear
          elsif pending.any?
            open = pending.values.first
            add(cursor, at, open.category, open.detail)
          else
            add(cursor, at, "inference", inference_detail(event))
          end

          if event.type == OpenTranscript::Types::TOOL_CALL
            pending[event.tool_call_id] = ToolClassifier.classify(event.tool_name, event.arguments)
            last_call_at = at
            result_since_call = false
            note_wake(event)
          end
        end

        cursor = at
        first = false
      end

      if pending.any?
        open = pending.values.first
        add(cursor, to, open.category, open.detail)
      else
        add(cursor, to, first ? "turn_startup" : "unattributed", first ? "turn produced no transcript events" : "turn wind-down")
      end
    end

    def inference_detail(event)
      case event.type
      when OpenTranscript::Types::TOOL_CALL then "deciding to call #{event.tool_name}"
      when OpenTranscript::Types::THINKING then "thinking"
      else "generating"
      end
    end

    # --- Not running ---------------------------------------------------------

    def build_waiting(state, from, to)
      case state
      when :queued then add(from, to, "wait_worker_queue", "turn queued for a worker thread")
      when :spot_hold then add(from, to, "wait_spot_hold", "held by the spot gate")
      when :quota_park then add(from, to, "wait_quota_park", "parked: account pool out of quota")
      when :elicitation then add(from, to, "wait_human", "MCP elicitation awaiting a human")
      when :failed then add(from, to, "unattributed", "failed")
      when :sleeping then add_sleep(from, to)
      when :needs_input then add_needs_input(from, to)
      when :archived then add(from, to, "unattributed", "archived, later restored")
      else add(from, to, "unattributed", state.to_s)
      end
    end

    def add_sleep(from, to)
      wake = @last_wake
      unless wake
        add(from, to, "wait_sleep", "asleep; no wake call found in the transcript")
        return
      end

      due = wake.due && [ wake.due, from ].max
      if due.nil? || to - due <= OVERDUE_GRACE
        add(from, to, wake.category, wake.detail)
        return
      end

      # The wake's purpose explains the sleep up to the time it was due. After
      # that the session was asleep on a wake that never fired, until a restart,
      # a sweep or a message reached it — no recorded event says what it was
      # waiting on, so the time is shown as such rather than charged to CI.
      @missed_wakes << MissedWake.new(due, to)
      add(from, due, wake.category, wake.detail)
      add(due, to, "unattributed", "asleep past its scheduled wake (due #{wake.due.utc.iso8601}); the wake did not fire")
    end

    # The part of a needs_input interval covered by a live child is a wait on
    # that child; the rest is holding a PR, or — when nothing ever resumed the
    # session and it sat parked until its archive — on the human action queue,
    # which is what needs_input means. A stretch something later resumed is
    # unexplained: the resume could have come from an agent or a trigger.
    def add_needs_input(from, to)
      rest =
        if @holds_pr then [ "wait_merge_gate", "needs_input holding an open PR" ]
        elsif to >= @span_end then [ "wait_human", "needs_input until it was archived (parked on the action queue)" ]
        else [ "unattributed", "needs_input until an agent or trigger resumed it" ]
        end
      cursor = from
      child_cover(from, to).each do |cover_from, cover_to|
        add(cursor, cover_from, *rest)
        add(cover_from, cover_to, "wait_child", "needs_input while a child session ran")
        cursor = cover_to
      end
      add(cursor, to, *rest)
    end

    # Merged [from, to] windows inside the interval during which a child was alive.
    def child_cover(from, to)
      windows = @child_windows.filter_map do |alive_from, alive_to|
        a = [ alive_from, from ].max
        b = [ alive_to, to ].min
        [ a, b ] if b > a
      end.sort

      windows.each_with_object([]) do |(a, b), merged|
        if merged.any? && a <= merged.last[1]
          merged.last[1] = [ merged.last[1], b ].max
        else
          merged << [ a, b ]
        end
      end
    end

    # Events that fall outside a running interval (clock skew between the CLI
    # and Rails, or a transition the timeline did not record) still tell us what
    # wake was armed, so they are read for that and otherwise skipped.
    def consume_events_until(to)
      while (event = @events[@event_index]) && event.at <= to
        note_wake(event) if event.type == OpenTranscript::Types::TOOL_CALL
        @event_index += 1
      end
    end

    # The wake a turn armed. A turn that watches a child and also arms the
    # `wake_me_up_later` backstop the skills ask for is waiting on the child;
    # the backstop is only the deadline.
    def note_wake(event)
      wake = WaitClassifier.classify_wake(event.tool_name, event.arguments)
      return if wake.nil?

      # The backstop still says when the watcher's wait was due to end.
      if @last_wake&.category == "wait_child" && wake.category == "wait_sleep"
        @last_wake = @last_wake.with(due: wake.due) if @last_wake.due.nil?
        return
      end

      @last_wake = wake
    end

    # --- Assembly ------------------------------------------------------------

    def add(from, to, category, detail)
      return unless to > from

      @segments << Segment.new(from, to, category, detail)
    end

    # Merge touching segments of the same category and detail. Lossless: every
    # total computed from the result is the same as from the raw cut.
    def compact(segments)
      merge(segments) { |a, b| a.category == b.category && a.detail == b.detail }
    end

    public

    # A copy of +segments+ small enough to store and draw: at most
    # MAX_SEGMENTS, by folding runs of short segments into buckets of about
    # span / MAX_SEGMENTS seconds, each shown as its dominant category. Totals,
    # the rollup and the top segments are computed from the full list — this
    # copy is for the Gantt chart only, where a bucket that narrow is a pixel.
    def self.for_display(segments, max: MAX_SEGMENTS)
      return segments if segments.size <= max

      # Every output segment is either at least a quantum long, or a bucket
      # closed by reaching a quantum or by the long segment after it — so each
      # kind numbers at most span / quantum, and three of them fit in +max+.
      span = segments.last.finish - segments.first.start
      quantum = span * 3 / max
      out = []
      bucket = []
      flush = lambda do
        next if bucket.empty?

        if bucket.size == 1
          out << bucket.first
        else
          by_category = bucket.group_by(&:category).transform_values { |list| list.sum(&:seconds) }
          dominant = by_category.max_by { |_, seconds| seconds }.first
          mix = by_category.sort_by { |_, s| -s }.first(3).map { |k, s| "#{Categories.label(k)} #{s.round}s" }.join(", ")
          out << Segment.new(bucket.first.start, bucket.last.finish, dominant, "#{bucket.size} short segments: #{mix}")
        end
        bucket = []
      end

      segments.each do |segment|
        if segment.seconds >= quantum
          flush.call
          out << segment
        else
          bucket << segment
          flush.call if bucket.last.finish - bucket.first.start >= quantum
        end
      end
      flush.call
      out
    end

    private

    def merge(segments)
      segments.each_with_object([]) do |segment, out|
        last = out.last
        if last && last.finish == segment.start && yield(last, segment)
          out[-1] = Segment.new(last.start, segment.finish, last.category, last.detail)
        else
          out << segment
        end
      end
    end
  end
end
