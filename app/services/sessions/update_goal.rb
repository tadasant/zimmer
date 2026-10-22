# frozen_string_literal: true

module Sessions
  # Sets, replaces or clears ONE session's goal, and logs the change.
  #
  # Every surface that changes a goal as an operation in its own right routes
  # through here: the web UI's Goal field (`PATCH /sessions/:id/update_goal`),
  # the `change_goal` MCP action, and `PATCH /api/v1/sessions/:id` with `goal`.
  #
  # Not the goal that rides along with a follow-up prompt. That one has a rule of
  # its own (a blank goal keeps the session's goal, an unknown id is skipped
  # rather than refused, the log line names the follow-up) and is
  # Sessions::FollowUpGoal.
  #
  # The rules:
  # - The goal is stripped of surrounding whitespace. Blank (nil, "", whitespace
  #   only) clears it, stored as NULL.
  # - Longer than Session::GOAL_MAX_LENGTH characters is refused (TooLong), never
  #   cut short: a goal is a definition of done, and its tail is as likely as its
  #   head to be the part that matters.
  # - A single id-shaped word that names no goal in config/goals.json is refused
  #   (UnknownGoalId), the typo check the model's goal_reference validation also
  #   makes. Only a goal this write changes is judged, so re-sending the session's
  #   own goal is never refused, even when that id has since been retired.
  # - Both refusals are raised before anything is written.
  # - The goal and its log row commit together. The "was" value is read from the
  #   stored row, so a retry after a failed write (the web door's with_db_retry)
  #   still logs the change. An unchanged goal writes no log row.
  #
  # Attributes the caller has already assigned on the session are saved by the
  # same `update!`. REST's PATCH relies on that to keep a goal change and its
  # other columns in one save, because `after_commit` callbacks read only the
  # last save's changes (the goal check panel's broadcast keys on
  # `saved_change_to_goal?`). A caller whose save is somebody else's write
  # (REST's PATCH with a `scheduling_class`, saved by
  # Sessions::UpdateSchedulingClass) passes a block: the goal is assigned, the
  # block does the save, and the log row follows it in the same transaction.
  class UpdateGoal
    class Error < StandardError
      # The refusal phrased to follow the word "Goal", the form a model error on
      # `goal` takes, for surfaces that report through `errors.add(:goal, …)`.
      attr_reader :reason

      def initialize(reason)
        @reason = reason
        super("Goal #{reason}")
      end
    end

    class TooLong < Error
      def initialize
        super("is too long (maximum #{Session::GOAL_MAX_LENGTH.to_fs(:delimited)} characters)")
      end
    end

    class UnknownGoalId < Error
      def initialize(goal)
        super(GoalsConfig.unknown_id_reason(goal))
      end
    end

    # Named in the log row.
    ACTOR_LABELS = { web: "", mcp: " via MCP", rest: " via the REST API" }.freeze

    # `previous_goal` is the stored goal, nil when there was none.
    Result = Data.define(:session, :previous_goal) do
      def changed?
        previous_goal != session.goal
      end
    end

    # @param session [Session]
    # @param goal [String, nil] the new goal; blank clears it
    # @param actor [Symbol] :web, :mcp or :rest — named in the log row
    # @yield the save, when the caller owns it; the goal is assigned beforehand
    # @return [Result]
    # @raise [TooLong] on a goal over Session::GOAL_MAX_LENGTH characters
    # @raise [UnknownGoalId] on an id-shaped goal the catalog does not have
    # @raise [ActiveRecord::RecordInvalid] when the session fails another validation
    def self.call(session:, goal:, actor:, &save)
      new(session: session, goal: goal, actor: actor).call(&save)
    end

    def initialize(session:, goal:, actor:)
      @session = session
      @goal = Sessions::FollowUpGoal.normalize(goal)
      @actor = actor
    end

    attr_reader :session, :goal, :actor

    def call
      label = ACTOR_LABELS.fetch(actor)
      raise TooLong if Sessions::FollowUpGoal.too_long?(goal)

      previous_goal = nil
      session.transaction do
        previous_goal = session.attribute_in_database("goal").presence
        # The same rule as Session's `goal_reference` validation (judged only on
        # a write that changes the goal), checked here so it is refused before
        # any save and worded the same at every door.
        raise UnknownGoalId, goal if goal != previous_goal && GoalsConfig.unknown_id?(goal)

        session.goal = goal
        block_given? ? yield : session.save!

        log_change(previous_goal, label) if previous_goal != goal
      end

      Result.new(session: session, previous_goal: previous_goal)
    end

    private

    def log_change(previous_goal, label)
      change = if goal.nil?
        "cleared"
      elsif previous_goal.nil?
        "set"
      else
        "updated"
      end
      session.logs.create!(content: "Goal #{change}#{label}", level: "info")
    end
  end
end
