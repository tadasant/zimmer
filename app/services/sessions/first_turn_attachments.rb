# frozen_string_literal: true

module Sessions
  # The attachments a session's first turn was created with, read back off the
  # durable volume.
  #
  # AgentSessionJob receives attachments ONLY as job arguments and never re-reads
  # them from disk, so every path that builds a first-turn job out of nothing has
  # to rebuild that metadata itself. Enqueuing without it started a session whose
  # prompt was "here is the screenshot, fix this" with the prompt and without the
  # screenshot — first from the Ranked view's Start entry and the stalled-session
  # sweep (#739), then from Restart from scratch (#746). The bytes were on the
  # durable volume the whole time, keyed by session id; nothing went looking for
  # them.
  #
  # == Only for a job built from nothing
  #
  # A queued AgentSessionJob already carries its own `images:`/`files:`
  # arguments. A caller that MOVES such a job — Sessions::StartNow pulling a held
  # turn forward — must not read this, or the turn arrives with a second copy.
  #
  # == "Everything on disk", minus what the queue owns
  #
  # Nothing records which attachments belonged to the first turn, so this reads
  # the session's whole storage directory and subtracts the paths an
  # EnqueuedMessage claims. A follow-up composed while the session sat unstarted
  # uploads through the same service into the same per-session directory, and
  # putting its screenshot on the turn before it would be the wrong turn.
  #
  # == It never raises
  #
  # Every caller is a start path, and one of them is Restart from scratch —
  # reached only when something has ALREADY gone wrong (a failed clone, a failed
  # spawn, the unattended fleet sweep). An exception here would refuse a restart
  # that succeeds today, which is strictly worse than the missing attachment this
  # exists to fix. Storage that cannot be read is a turn with no attachments
  # (SessionAttachmentStorage.stored_for is best-effort in exactly the same way),
  # and a queue that cannot be read degrades to the same answer rather than
  # risking the duplicate: a turn short an attachment is a worse turn, a turn
  # carrying somebody else's is a wrong one.
  class FirstTurnAttachments
    # @param session [Session]
    # @return [Array(Array<Hash>, Array<Hash>)] images, files — each entry in the
    #   shape AgentSessionJob.enqueue_new_session takes
    def self.for(session)
      claimed = paths_claimed_by_the_queue(session)
      return [ [], [] ] if claimed.nil?

      [
        ImageStorageService.stored_for(session.id),
        FileStorageService.stored_for(session.id)
      ].map { |attachments| attachments.reject { |entry| claimed.include?(entry[:path]) } }
    rescue StandardError => e
      # The class contract above, made structural: no caller of a start path
      # should have to rescue to keep starting.
      Rails.logger.warn(
        "[Sessions::FirstTurnAttachments] Could not read session #{session&.id}'s attachments: #{e.class}: #{e.message}"
      )
      [ [], [] ]
    end

    # What the turn is carrying, for a log line a human reads. nil when it
    # carries nothing: a first turn with no attachments is the ordinary case, and
    # saying so every time would bury the times it does.
    #
    # @return [String, nil] e.g. "1 image and 2 files"
    def self.phrase(images, files)
      carried = []
      carried << "#{images.size} #{"image".pluralize(images.size)}" if images.any?
      carried << "#{files.size} #{"file".pluralize(files.size)}" if files.any?
      return nil if carried.empty?

      carried.to_sentence
    end

    # Attachment paths that belong to a QUEUED message rather than to the first
    # turn.
    #
    # @return [Set<String>, nil] nil when the queue could not be read, which is
    #   NOT the same answer as "nothing is queued"
    def self.paths_claimed_by_the_queue(session)
      session.enqueued_messages
             .flat_map { |message| Array(message.images) + Array(message.files) }
             .filter_map { |entry| entry["path"] || entry[:path] if entry.is_a?(Hash) }
             .to_set
    rescue StandardError => e
      Rails.logger.warn(
        "[Sessions::FirstTurnAttachments] Could not read session #{session.id}'s queued messages: #{e.message}"
      )
      nil
    end
    private_class_method :paths_claimed_by_the_queue
  end
end
