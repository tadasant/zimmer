# frozen_string_literal: true

module CycleTimes
  # Reads a session's timeline (`logs`) back into the state changes it records.
  #
  # The timeline is the authoritative history of a session's lifecycle: every
  # AASM transition writes one `[State Machine]` line through
  # Session#log_state_change, and the spot gate and the quota parks write their
  # own warning lines. Nothing else stores *when* a session went to sleep, was
  # queued, or was held, so this parser is the bridge — and it keys on the
  # leading words those writers use, which are the contract:
  #
  #   SessionStateMachine     "Turn started on a worker" / "Session started"
  #                           "Session sleeping, waiting for scheduled wake-up"
  #                           "Session paused, waiting for input"
  #                           "Session resumed — its turn is queued for a worker"
  #                           "Session blocked on MCP elicitation" / "... unblocked ..." (:resumed —
  #                           the same process, picking its turn back up)
  #                           "Session failed: ..." / "Session moved to trash by <actor>"
  #                           "Session restored from trash to <state>"
  #   SpotSessionHold         "Spot session held ..."
  #   AuthOutageParkService   "Quota exceeded across all ..." / "No usable ... login available."
  #   ProviderQuotaWallPark   "Provider quota wall ..."
  #
  # `test/services/cycle_times/state_log_test.rb` pins these against the writers'
  # literal strings so a reworded log line fails a test rather than silently
  # turning a queue wait into unattributed time.
  module StateLog
    Change = Data.define(:at, :kind, :detail)

    STATE_MACHINE = "[State Machine] "

    TRANSITIONS = [
      [ /\A(?:Turn started on a worker|Session started)\b/, :running ],
      [ /\ASession unblocked from MCP elicitation/, :resumed ],
      [ /\ASession sleeping\b/, :sleeping ],
      [ /\ASession paused\b/, :needs_input ],
      [ /\ASession resumed\b/, :queued ],
      [ /\ASession blocked on MCP elicitation/, :elicitation ],
      [ /\ASession failed\b/, :failed ],
      [ /\ASession moved to trash\b/, :archived ],
      [ /\ASession restored from trash to waiting/, :queued ],
      [ /\ASession restored from trash to needs_input/, :needs_input ],
      [ /\ASession restored from trash to failed/, :failed ]
    ].freeze

    OVERLAYS = [
      [ /\ASpot session held\b/, :spot_hold ],
      [ /\A(?:Quota exceeded across all|No usable .{1,40} login available|Provider quota wall)\b/, :quota_park ]
    ].freeze

    module_function

    # @param logs [Enumerable<#created_at, #content>] a session's timeline rows
    # @return [Array<Change>] in time order
    def parse(logs)
      logs.filter_map { |log| change_for(log.created_at, log.content.to_s) }.sort_by(&:at)
    end

    def change_for(at, content)
      if content.start_with?(STATE_MACHINE)
        text = content.delete_prefix(STATE_MACHINE)
        kind = TRANSITIONS.find { |pattern, _| text.match?(pattern) }&.last
        return kind && Change.new(at, kind, text)
      end

      kind = OVERLAYS.find { |pattern, _| content.match?(pattern) }&.last
      kind && Change.new(at, kind, content.truncate(140))
    end

    # The actor phrases of every archive the timeline records, oldest first.
    def archive_actors(changes)
      changes.select { |c| c.kind == :archived }.map { |c| c.detail.sub(/\ASession moved to trash(?: by )?/, "").split(" — ").first.to_s }
    end
  end
end
