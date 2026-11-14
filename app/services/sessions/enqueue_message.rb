# frozen_string_literal: true

module Sessions
  # Adds a message to the tail of a session's queue, on request.
  #
  # The three "add to queue" doors take this path: the web queue form
  # (`POST /sessions/:id/enqueued_messages`), the REST endpoint
  # (`POST /api/v1/sessions/:id/enqueued_messages`) and the `create` action of
  # the `manage_enqueued_messages` MCP tool. Each one asks for a message to be
  # queued regardless of whether a turn is underway, which is what separates it
  # from Sessions::QueueFollowUp: that one queues a follow-up *because* a turn is
  # in flight, and says so in its log row. This one writes the plain row,
  # "Enqueued message added at position N".
  #
  # The position is read through Sessions::QueueTail, under a row lock on the
  # session, in the same transaction as the insert and the log row, so it is
  # ordered against QueueFollowUp and Sessions::InterruptWithFollowUp as well as
  # against itself. A collision with a writer that still computes its own
  # `maximum + 1` surfaces as `ActiveRecord::RecordNotUnique`.
  #
  # A message that fails validation is not raised: it comes back unpersisted,
  # with its `errors`, and nothing is written — REST and MCP report those errors
  # in their own words. Callers that want an exception check `persisted?`.
  #
  # Scope: one EnqueuedMessage and one Log row, committed together. It does not
  # check the session's status, record the human or assistant message, the
  # uncle edge or user activity, and renders nothing. Not idempotent: a second
  # call queues a second message.
  class EnqueueMessage
    # @param session [Session]
    # @param content [String] the message text
    # @param goal [String, nil] carried on the message
    # @param source_context [Hash] the surface's turn source (`TurnSource#to_h`)
    # @param images [Array<Hash>, nil] attachment descriptors; the column default when nil
    # @param files [Array<Hash>, nil] attachment descriptors; the column default when nil
    # @return [EnqueuedMessage] persisted, or unpersisted with `errors` when invalid
    # @raise [ActiveRecord::RecordNotUnique] when a writer outside Sessions::QueueTail took the position
    def self.call(session:, content:, goal:, source_context:, images: nil, files: nil)
      new(session:, content:, goal:, source_context:, images:, files:).call
    end

    def initialize(session:, content:, goal:, source_context:, images: nil, files: nil)
      @session = session
      @attributes = {
        content: content,
        goal: goal,
        status: "pending",
        source_context: source_context,
        **{ images: images, files: files }.compact
      }
    end

    def call
      session.transaction do
        message = session.enqueued_messages.new(attributes.merge(position: QueueTail.next_position!(session)))
        next message unless message.save

        session.logs.create!(content: "Enqueued message added at position #{message.position}", level: "info")
        message
      end
    end

    private

    attr_reader :session, :attributes
  end
end
