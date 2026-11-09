# frozen_string_literal: true

module Sessions
  # A person started, followed up or acted on this session from CarPlay — so keep
  # it in the driver's `not_laptop_only` view.
  #
  # Stamps `carplay_engaged_at` and writes the sticky CarPlay default: a
  # `carplay_ok` mark with source `carplay`, which does not go stale
  # (SessionCarplayFit). Every CarPlay entry path calls it:
  #
  # - a session CREATED with a CarPlay turn source — the iOS app's CarPlay
  #   screen over REST, or a Live Mode conversation on CarPlay calling
  #   `start_session` / `quick_router` (Session's after_create_commit);
  # - a FOLLOW-UP delivered directly with a CarPlay turn source (Session#tag_turn)
  #   — and a message QUEUED from CarPlay, at the moment it is queued
  #   (EnqueuedMessage's after_create_commit; never on the drain, and never for
  #   a row Zimmer puts back in the queue);
  # - most other `action_session` actions a CarPlay Live Mode conversation takes
  #   on a session (unarchive, pause, restart, change_goal, …), and the matching
  #   member writes over REST from the CarPlay client.
  #
  # Reads are not engagement: a driver's assistant listing or reading the board
  # touches every row it looks at, and marking them all would empty the axis of
  # meaning. Neither is an explicit `set_carplay_fit` — that write says what the
  # mark should be, and is left alone.
  #
  # **Re-engagement does not override a current `laptop_only`.** If the session
  # was demoted and has not said anything since, the requirement still stands as
  # of now: the stamp is recorded and the mark kept. The engagement itself is
  # usually a follow-up, so the session soon writes past the demotion; when it
  # next comes to rest the status-summary fork — told the session is
  # CarPlay-engaged — re-judges, and its `carplay_ok` restores the sticky default
  # (SessionCarplayFit#automatic_carplay_fit_source). A stale `laptop_only` (the
  # session has moved past it) is promoted at once.
  #
  # Best-effort: an engagement record must never fail the turn or action it
  # rides on.
  class RecordCarplayEngagement
    CARPLAY_SURFACE = "carplay"

    Result = Struct.new(:outcome, :message, keyword_init: true)

    # Whether a TurnSource (or anything with a `surface`) came from CarPlay.
    def self.carplay?(source)
      source.respond_to?(:surface) && source.surface.to_s == CARPLAY_SURFACE
    end

    # Records the engagement when `source` is CarPlay; nil otherwise.
    #
    # @param session [Session]
    # @param source [TurnSource, nil]
    # @return [Result, nil]
    def self.from_source(session, source)
      return nil unless carplay?(source)

      call(session)
    end

    # @param session [Session]
    # @return [Result] outcome :marked, :kept_laptop_only, :already_marked, :kept, or :failed
    def self.call(session)
      new(session).call
    end

    # The columns this writes, copied back onto the caller's object afterwards.
    COLUMNS = %w[carplay_engaged_at carplay_fit carplay_fit_reason carplay_fit_source
                 carplay_fit_set_at carplay_fit_line_count].freeze

    # Works on a fresh copy of the row, never on the caller's object: the
    # follow-up paths call this mid-delivery, holding a session with attributes
    # they have not saved yet, and a save here must not write those for them.
    # The result is copied back onto the caller's object as already-persisted
    # values, so its later reads and broadcasts see the new mark.
    def initialize(session)
      @caller_session = session
    end

    attr_reader :session

    # In a savepoint: the follow-up paths call this inside their own
    # transaction, and a database error here must roll back only this write,
    # not leave Postgres's transaction aborted under the caller.
    def call
      Session.transaction(requires_new: true) { record }
    rescue StandardError => e
      Rails.logger.error("[Sessions::RecordCarplayEngagement] Could not record CarPlay engagement on session #{@caller_session&.id}: #{e.class}: #{e.message}")
      @session = nil
      Result.new(outcome: :failed, message: e.message)
    ensure
      sync_back
    end

    private

    def record
      @session = Session.find(@caller_session.id)
      session.update_columns(carplay_engaged_at: Time.current)

      if session.carplay_fit_sticky?
        return Result.new(outcome: :already_marked, message: "Already held CarPlay-ok from CarPlay engagement.")
      end

      if session.carplay_fit_current? && session.carplay_fit == SessionCarplayFit::LAPTOP_ONLY
        return Result.new(outcome: :kept_laptop_only,
                          message: "Kept the current laptop-only mark (#{session.carplay_fit_summary}); " \
                                   "the next rest re-judges it with the CarPlay engagement in mind.")
      end

      written = Sessions::SetCarplayFit.call(
        session: session,
        fit: SessionCarplayFit::CARPLAY_OK,
        source: SessionCarplayFit::SOURCE_CARPLAY,
        reason: carried_reason
      )
      Result.new(outcome: written.applied? ? :marked : :kept, message: written.message)
    end

    def sync_back
      return if session.nil? || @caller_session.equal?(session)

      COLUMNS.each { |column| @caller_session[column] = session[column] }
      @caller_session.clear_attribute_changes(COLUMNS)
    rescue StandardError => e
      Rails.logger.error("[Sessions::RecordCarplayEngagement] Could not refresh session #{session&.id}: #{e.class}: #{e.message}")
    end

    # A current `carplay_ok` already said why; keep that reason rather than
    # dropping it for a bare mark.
    def carried_reason
      return nil unless session.carplay_fit_current? && session.carplay_fit == SessionCarplayFit::CARPLAY_OK

      session.carplay_fit_reason
    end
  end
end
