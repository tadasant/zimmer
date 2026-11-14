# frozen_string_literal: true

module Sessions
  # Stages a new message at the tail of a session's queue and delivers it now,
  # ending the turn in flight.
  #
  # Every door that sends a NEW message "right now" takes this path: the REST
  # follow-up with `force_immediate` (`POST /api/v1/sessions/:id/follow_up`), the
  # `follow_up` action of the `action_session` MCP tool with `force_immediate`,
  # the `send_now` action of the `manage_enqueued_messages` MCP tool, and
  # Sessions::MessageParent when a child reports back with `force_immediate`.
  # The web "Send Now" button is not one of them: it promotes a message that is
  # already in the queue, so it hands that row straight to
  # Sessions::InterruptService and has nothing to stage.
  #
  # Three steps, in this order:
  #
  # 1. Stage. The message is created `pending` at the tail, with the position
  #    read through Sessions::QueueTail under a row lock on the session, and
  #    committed. The commit comes before step 3 on purpose:
  #    Sessions::InterruptService takes a per-session advisory lock of its own,
  #    and holding a row lock across it is how two locks become a deadlock.
  # 2. The caller's block, if given, runs with the staged message. A surface
  #    uses it for what must happen after the message exists and before the
  #    turn it starts can read the session — recording the human's words.
  # 3. Interrupt, through Sessions::InterruptService, which promotes the staged
  #    message to the head of the queue and dispatches it.
  #
  # All-or-nothing. When the interrupt fails, or the caller's block raises, the
  # staged message is withdrawn — destroyed if it is still
  # `pending` — so it does not arrive later as a surprise queued follow-up. A
  # concurrent interrupt may already have claimed it, in which case it is being
  # delivered and is left alone; `withdrawn?` on the result says which.
  # InterruptService answers its own failures with a result, so the rescue
  # around it is defensive; the block is what can realistically raise.
  #
  # Scope: the message and the interrupt. It does not check the session's
  # status (each surface refuses a session it cannot send to in its own words,
  # and InterruptService re-checks under its lock), does not record the uncle
  # edge, user activity or attachments in the log, and renders nothing.
  class InterruptWithFollowUp
    Result = Struct.new(:success, :error, :error_code, :enqueued_message, :withdrawn, keyword_init: true) do
      def success?
        success
      end

      # True when this call destroyed the staged message after a failure. False
      # on success, and on a failure where a concurrent interrupt had already
      # claimed the message — it is being delivered, attachments and all.
      def withdrawn?
        withdrawn
      end
    end

    # @param session [Session]
    # @param prompt [String] the message text, already validated by the caller
    # @param actor [String] recorded by InterruptService for observability
    # @param goal [String, nil] carried on the message; EnqueuedMessageProcessorService
    #   applies a non-blank one when it claims the message
    # @param source_context [Hash, nil] the surface's turn source (`TurnSource#to_h`)
    # @param origin [String, nil] the message's origin; the column default when nil
    # @param images [Array<Hash>, nil] attachment descriptors for the record
    # @param files [Array<Hash>, nil] attachment descriptors for the record
    # @yieldparam enqueued_message [EnqueuedMessage] the staged message, before the interrupt
    # @return [Result]
    # @raise [ActiveRecord::RecordInvalid] when the message fails a validation (nothing is staged)
    # @raise [ActiveRecord::RecordNotUnique] when a writer outside Sessions::QueueTail took the position
    def self.call(session:, prompt:, actor:, goal: nil, source_context: nil, origin: nil, images: nil, files: nil, &before_interrupt)
      new(session:, prompt:, actor:, goal:, source_context:, origin:, images:, files:).call(&before_interrupt)
    end

    def initialize(session:, prompt:, actor:, goal: nil, source_context: nil, origin: nil, images: nil, files: nil)
      @session = session
      @actor = actor
      @attributes = {
        content: prompt,
        goal: goal,
        status: "pending",
        source_context: source_context,
        origin: origin,
        images: images,
        files: files
      }.compact
    end

    def call
      enqueued_message = stage

      begin
        yield enqueued_message if block_given?
        result = Sessions::InterruptService.new(
          session: session,
          enqueued_message: enqueued_message,
          actor: actor
        ).call
      rescue StandardError => e
        withdraw_after(e, enqueued_message)
        raise
      end

      if result.success?
        Result.new(success: true, enqueued_message: enqueued_message, withdrawn: false)
      else
        Result.new(
          success: false,
          error: result.error,
          error_code: result.error_code,
          enqueued_message: enqueued_message,
          withdrawn: withdraw(enqueued_message)
        )
      end
    end

    private

    attr_reader :session, :actor, :attributes

    def stage
      session.transaction do
        session.enqueued_messages.create!(**attributes, position: QueueTail.next_position!(session))
      end
    end

    # A cleanup that fails must not replace the error that caused it.
    def withdraw_after(error, enqueued_message)
      withdraw(enqueued_message)
    rescue StandardError => cleanup_error
      Rails.logger.warn(
        "[Sessions::InterruptWithFollowUp] could not withdraw message #{enqueued_message.id} " \
        "after #{error.class}: #{cleanup_error.class}: #{cleanup_error.message}"
      )
    end

    # @return [Boolean] whether this call destroyed the message
    def withdraw(enqueued_message)
      enqueued_message.reload
      return false unless enqueued_message.status == "pending"

      enqueued_message.destroy!
      true
    rescue ActiveRecord::RecordNotFound
      # A concurrent interrupt claimed and delivered it: nothing to withdraw.
      false
    end
  end
end
