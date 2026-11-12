# frozen_string_literal: true

module Sessions
  # Queues a follow-up prompt behind a turn that is already underway.
  #
  # All three follow-up doors take this branch when `Sessions::LiveTurn.underway?`
  # says a turn is in flight — the web form (`POST /sessions/:id/follow_up`), the
  # REST endpoint (`POST /api/v1/sessions/:id/follow_up`) and the `follow_up`
  # action of the `action_session` MCP tool. Rather than reject a prompt that
  # raced the end of a turn, each one parks it at the tail of the session's
  # queue, and EnqueuedMessageProcessorService delivers it when the turn ends.
  # This is that branch, written once: the next position, the pending
  # EnqueuedMessage, and the one log row that records it.
  #
  # Position assignment is serialized per session. The read of
  # `maximum(:position)` and the insert run in one transaction under a row lock
  # on the session (`SELECT … FOR UPDATE`, taken without reloading the caller's
  # instance), so two follow-ups queued at once land at N+1 and N+2 instead of
  # both reading N and the second dying on the deferred
  # `(session_id, position)` unique constraint at COMMIT. The lock only orders
  # callers of this service: the other writers of the queue still compute their
  # own `maximum + 1`, and a collision with one of them still surfaces as
  # `ActiveRecord::RecordNotUnique`, which the caller handles as it always has.
  #
  # Scope: one EnqueuedMessage and one Log row, committed together. It does not
  # decide whether a turn is underway (the caller asked `LiveTurn` first), does
  # not record the human message, the uncle edge or user activity, and renders
  # nothing — every surface keeps its own response. Not idempotent: a second
  # call queues a second message.
  class QueueFollowUp
    # The timeline row every surface writes. One wording, because the three doors
    # queue for the same reason: `LiveTurn.underway?` — which is also true of a
    # turn still waiting for a worker, so "session is running" would be false there.
    LOG_REASON = "a turn is already underway"

    # @param session [Session]
    # @param prompt [String] the follow-up text, already validated by the caller
    # @param goal [String, nil] carried on the message; EnqueuedMessageProcessorService
    #   applies a non-blank one when it claims the message
    # @param source_context [Hash] the surface's turn source (`TurnSource#to_h`)
    # @param images [Array<Hash>, nil] attachment descriptors for the record
    # @param files [Array<Hash>, nil] attachment descriptors for the record
    # @return [EnqueuedMessage] the pending message, persisted
    # @raise [ActiveRecord::RecordInvalid] when the message fails a validation
    # @raise [ActiveRecord::RecordNotUnique] when a writer outside this service took the position
    def self.call(session:, prompt:, goal:, source_context:, images: nil, files: nil)
      new(session:, prompt:, goal:, source_context:, images:, files:).call
    end

    def initialize(session:, prompt:, goal:, source_context:, images: nil, files: nil)
      @session = session
      @prompt = prompt
      @goal = goal
      @source_context = source_context
      @attachments = { images: images, files: files }.compact
    end

    def call
      session.transaction do
        Session.where(id: session.id).lock.pick(:id)
        position = (session.enqueued_messages.maximum(:position) || 0) + 1

        enqueued_message = session.enqueued_messages.create!(
          content: prompt,
          goal: goal,
          position: position,
          status: "pending",
          source_context: source_context,
          **attachments
        )
        session.logs.create!(
          content: "Message queued at position #{position} (#{LOG_REASON})",
          level: "info"
        )
        enqueued_message
      end
    end

    private

    attr_reader :session, :prompt, :goal, :source_context, :attachments
  end
end
