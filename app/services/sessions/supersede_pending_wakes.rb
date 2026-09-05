# frozen_string_literal: true

module Sessions
  # Cancels a session's unfired one-time schedule wakes.
  #
  # This is the "not then, THIS instead" half of a park into the spot queue: that
  # park arms nothing at all, so a wake left over from an earlier
  # `wake_me_up_later` would pull the session straight back out of the queue it
  # was just put in.
  #
  # `wake_me_up_later` itself keeps the additive behaviour and never goes through
  # here: arming several wakes at once is the documented pattern (a wall-clock
  # backstop beside a `wake_me_up_when_session_changes_state` watcher), whichever
  # fires first wins, and Trigger#hold_wake_group! cleans up the rest.
  class SupersedePendingWakes
    # @param session [Session]
    # @param note [String] what the session's log calls the thing that replaced
    #   the wake. The one caller passes "Spot Queue"; the default is here so a
    #   future one is not forced to invent a label to call this at all
    # @return [Array<Integer>] ids of the triggers destroyed
    def self.call(session:, note: "Superseded")
      new(session: session, note: note).call
    end

    def initialize(session:, note:)
      @session = session
      @note = note
    end

    attr_reader :session, :note

    def call
      candidates = superseded_candidates
      return [] if candidates.empty?

      destroyed = candidates.map do |trigger|
        trigger.destroy!
        trigger.id
      end

      session.logs.create!(
        content: "[#{note}] Superseded pending wake-up trigger(s) #{destroyed.join(', ')}",
        level: "info"
      )

      destroyed
    end

    private

    # Only triggers whose SOLE condition is an unfired one-time schedule are
    # destroyed: a trigger carrying other conditions (OR semantics) does other
    # work, and a session-scoped ao_event wake answers a different question
    # ("when X happens") that a chosen wall-clock time does not supersede.
    def superseded_candidates
      # preload, NOT includes. `includes` alongside `joins` + a
      # `trigger_conditions` WHERE turns this into a single eager-loading LEFT
      # JOIN, so `trigger.trigger_conditions` would come back holding only the
      # conditions that matched the filter. Both things below then break: a
      # multi-condition trigger looks single-condition and gets selected, and
      # `destroy!` cascades over the truncated association, leaving the unloaded
      # rows behind to violate their foreign key. preload issues a second,
      # unfiltered query.
      Trigger
        .joins(:trigger_conditions)
        .where(reuse_session: true, last_session_id: session.id, status: "enabled")
        .where(trigger_conditions: { condition_type: "schedule", last_triggered_at: nil })
        .distinct
        .preload(:trigger_conditions)
        .select { |trigger| trigger.trigger_conditions.one? && trigger.trigger_conditions.sole.one_time_schedule? }
    end
  end
end
