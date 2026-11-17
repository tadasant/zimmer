# frozen_string_literal: true

module CycleTimes
  # Whether a settled hierarchy was completed end to end autonomously.
  #
  # THE RULE. A hierarchy qualifies when all of these hold:
  #
  #   1. Every session in it is archived (otherwise it is in flight, and no row
  #      is written at all).
  #   2. Every archive of every session was performed by an agent — the session
  #      itself or another session IN THE SAME HIERARCHY, over MCP, or the
  #      fleet's REST API — as recorded on the timeline by ArchiveActor. A
  #      web-UI Trash, a Live Mode archive, one of Zimmer's sweeps, an archive
  #      with no recorded actor, or an archive by a session outside the
  #      hierarchy (a fleet-cleanup agent closing a parked session is a sweep
  #      by another name: the task did not archive itself) disqualifies it.
  #   3. The human-messages record (HumanMessage, written only at an
  #      authenticated input boundary) holds no message on any session in the
  #      hierarchy except the initiating prompt: a message on the ROOT recorded
  #      no later than INITIATION_GRACE after its first turn started (or after
  #      its creation, if it never started a turn before the message).
  #   4. No session in it was restored from the trash. A reopened session's span
  #      contains its time in the trash, and the work after it is a second task.
  #   5. It has at most Hierarchy::MAX_SESSIONS sessions.
  #   6. No session slept more than MISSED_WAKE_LIMIT past a scheduled wake that
  #      did not fire (LaneBuilder#missed_wakes). That task stalled: something
  #      outside it — a restart, a recovery sweep, a person — had to wake it, so
  #      it did not finish on its own, and its wall-clock measures the missed
  #      trigger rather than the work. This needs the built lanes, so the
  #      Analyzer applies it through .missed_wake after the rest of the rule.
  #
  # The initiator is recorded either way: `human` when the root carries an
  # initiating human message, `trigger` when a Zimmer trigger created the root,
  # `other` otherwise (an API client, or an agent starting a root session).
  class Eligibility
    Result = Data.define(:eligible, :reason, :detail, :initiator, :initiator_detail)

    INITIATION_GRACE = 2.minutes

    MISSED_WAKE_LIMIT = 1.hour

    REASONS = {
      "human_archive" => "A human archived a session",
      "system_archive" => "One of Zimmer's sweeps archived a session",
      "unrecorded_archive" => "A session's archive has no recorded actor",
      "human_follow_up" => "A human sent a message after the initiating prompt",
      "reopened" => "A session was restored from the trash",
      "too_large" => "More sessions than the analysis handles",
      "outside_archive" => "A session outside the task archived one of its sessions",
      "missed_wake" => "A session slept long past a wake that never fired"
    }.freeze

    # Rule 6. The disqualifying [reason, detail], or nil.
    #
    # @param missed_by_session [Hash{Integer => Array<LaneBuilder::MissedWake>}]
    def self.missed_wake(missed_by_session)
      session_id, missed = missed_by_session
                           .flat_map { |id, list| list.map { |m| [ id, m ] } }
                           .max_by { |_, m| m.seconds }
      return nil if missed.nil? || missed.seconds <= MISSED_WAKE_LIMIT

      [ "missed_wake",
        "session ##{session_id}'s wake was due #{missed.due.utc.iso8601} and it slept until " \
        "#{missed.resumed.utc.iso8601} (#{ActiveSupport::Duration.build(missed.seconds.round).inspect} late)" ]
    end

    # @param hierarchy [Hierarchy]
    # @param changes_by_session [Hash{Integer => Array<StateLog::Change>}]
    # @param human_messages [Array<HumanMessage>] every record on the hierarchy's sessions
    def initialize(hierarchy, changes_by_session:, human_messages:)
      @hierarchy = hierarchy
      @changes = changes_by_session
      @human_messages = human_messages
    end

    def call
      initiator, initiator_detail = initiator_fields
      reason, detail = disqualification
      Result.new(eligible: reason.nil?, reason: reason, detail: detail, initiator: initiator, initiator_detail: initiator_detail)
    end

    def initiating_messages
      @initiating_messages ||= begin
        root = @hierarchy.root
        first_turn = Array(@changes[root.id]).find { |c| c.kind == :running }&.at
        deadline = [ first_turn, root.created_at ].compact.max + INITIATION_GRACE
        @human_messages.select { |m| m.session_id == root.id && m.occurred_at <= deadline }
      end
    end

    private

    def disqualification
      return [ "too_large", "over #{Hierarchy::MAX_SESSIONS} sessions" ] if @hierarchy.too_large?

      @hierarchy.sessions.each do |session|
        changes = Array(@changes[session.id])
        if changes.any? { |c| c.detail.to_s.start_with?("Session restored from trash") }
          return [ "reopened", "session ##{session.id} was restored from the trash" ]
        end

        actors = StateLog.archive_actors(changes)
        return [ "unrecorded_archive", "session ##{session.id} has no archive line on its timeline" ] if actors.empty?

        actors.each do |phrase|
          case ArchiveActor.classify(phrase)
          when :human then return [ "human_archive", "session ##{session.id} archived by #{phrase}" ]
          when :system then return [ "system_archive", "session ##{session.id} archived by #{phrase}" ]
          when :unrecorded then return [ "unrecorded_archive", "session ##{session.id} archived by #{phrase.presence || 'an unrecorded caller'}" ]
          when :agent
            archiver = ArchiveActor.session_id(phrase)
            if archiver && !hierarchy_ids.include?(archiver)
              return [ "outside_archive", "session ##{session.id} archived by #{phrase}, which is not part of this task" ]
            end
          end
        end
      end

      follow_up = (@human_messages - initiating_messages).min_by(&:occurred_at)
      if follow_up
        return [ "human_follow_up", "#{follow_up.author} on session ##{follow_up.session_id} at #{follow_up.occurred_at.utc.iso8601} (#{follow_up.channel})" ]
      end

      nil
    end

    def hierarchy_ids
      @hierarchy_ids ||= @hierarchy.sessions.map(&:id).to_set
    end

    def initiator_fields
      root = @hierarchy.root
      if (message = initiating_messages.first)
        [ "human", "#{message.author} via #{message.channel}" ]
      elsif (trigger_id = root.metadata&.dig("trigger_id")).present?
        name = Trigger.where(id: trigger_id).pick(:name)
        [ "trigger", name.presence || "trigger ##{trigger_id}" ]
      else
        [ "other", "API or agent" ]
      end
    end
  end
end
