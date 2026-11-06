# frozen_string_literal: true

module LiveConversations
  # Make another conversation the current one: end whatever is open and reopen
  # the target, in one transaction. Live Mode stays one current thread; this
  # moves which one it is. With no id, the target is the one left most recently,
  # so "go back" needs no list and a second "go back" undoes the first.
  #
  # `from_id` says which conversation the caller believes is current. If another
  # one is by the time this runs, the person is looking at something stale, and
  # moving them from a conversation they cannot see is refused. The target
  # already being current is a no-op, not an error, which is also how the loser
  # of two racing switches to the same place comes out.
  #
  # Two switches to different places serialize on the row locks, and the unique
  # index on open conversations catches what the locks cannot see: a conversation
  # that opened after the lock was taken.
  class Switch
    # `moved`: false when the target was already current. `left`: the
    # conversations this ended.
    Outcome = Data.define(:conversation, :moved, :left)

    def self.call(id = nil, from_id: nil, mode: nil, client_surface: nil)
      new(id, from_id:, mode:, client_surface:).call
    end

    def initialize(id, from_id: nil, mode: nil, client_surface: nil)
      @id = id
      @from_id = from_id.presence && Integer(from_id, exception: false)
      @mode = mode.presence&.to_s
      @client_surface = LiveConversation.normalize_client_surface(client_surface)
    end

    # @return [Outcome]
    # @raise [Actions::Refused] with a message to say to the person as it is
    def call
      availability = Availability.current
      raise Actions::Refused.new(availability.reasons.join(" "), status: :service_unavailable) unless availability.available?
      raise Actions::Refused, "mode must be one of: #{LiveConversations.mode_keys.join(', ')}" if @mode && !LiveConversations.mode_keys.include?(@mode)

      target_id = resolve_target_id
      attempts = 0
      begin
        attempts += 1
        move_to(target_id)
      rescue ActiveRecord::RecordNotUnique
        current = LiveConversation.current
        return Outcome.new(conversation: current, moved: false, left: []) if current&.id == target_id
        raise Actions::Refused.new(changed_message(current), status: :conflict) if attempts > 1

        retry
      end
    end

    private

    def resolve_target_id
      return LiveConversation.previous&.id || raise(Actions::Refused.new("There is no earlier conversation to go back to.", status: :conflict)) if @id.blank?

      Integer(@id, exception: false) || raise(Actions::Refused.new("Live conversation not found: #{@id}", status: :not_found))
    end

    def move_to(target_id)
      outcome = LiveConversation.transaction do
        # One ordered statement, so two switches take their locks in the same order.
        rows = LiveConversation.where(status: LiveConversation::OPEN_STATUSES).or(LiveConversation.where(id: target_id)).order(:id).lock.to_a
        target = rows.find { |row| row.id == target_id } || raise(Actions::Refused.new("Live conversation not found: #{target_id}", status: :not_found))
        next Outcome.new(conversation: target, moved: false, left: []) if target.open?

        refuse_unless_reopenable!(target)
        open_rows = rows.select(&:open?)
        current = open_rows.max_by(&:id)
        raise Actions::Refused.new(changed_message(current), status: :conflict) if @from_id && current && current.id != @from_id

        open_rows.each(&:end!)
        target.reopen!(mode: @mode || current&.mode || target.mode, client_surface: @client_surface)
        Outcome.new(conversation: target, moved: true, left: open_rows)
      end
      settle(outcome.conversation) if outcome.moved
      outcome
    end

    def refuse_unless_reopenable!(target)
      return if target.reopenable?

      message = target.failed? ? "That conversation failed, so it can't be gone back to. Start a new one." : "That conversation is from an older Live Mode and can only be read."
      raise Actions::Refused.new(message, status: :conflict)
    end

    def changed_message(current)
      "The current conversation changed#{current ? " to \"#{current.spoken_title}\"" : ''}. Look again before switching."
    end

    # After the commit. A line typed and never answered gets its answer, as when
    # voice goes off; the instructions catch up in the background, or are read
    # for the first time when it never got that far.
    def settle(conversation)
      return LiveConversationPrepareJob.perform_later(conversation.id) if conversation.preparing?

      LiveConversationPrepareJob.perform_later(conversation.id, refresh: true)
      LiveConversationReplyJob.perform_later(conversation.id) if conversation.text? && conversation.turns.reorder(id: :desc).first&.user?
    end
  end
end
