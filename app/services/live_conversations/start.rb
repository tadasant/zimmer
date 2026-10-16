# frozen_string_literal: true

module LiveConversations
  # Start a fresh conversation in a mode, ending the one that was open — a mode
  # has one current thread. The new conversation is `preparing` until
  # LiveConversationPrepareJob has read its root's AGENTS.md.
  class Start
    class Unavailable < StandardError; end

    def self.call(mode_key) = new(mode_key).call

    def initialize(mode_key)
      @availability = Availability.for(mode_key)
    end

    # @return [LiveConversation]
    # @raise [Unavailable] with a message naming what is missing
    def call
      raise Unavailable, @availability.reasons.join(" ") unless @availability.available?

      mode = @availability.mode
      root = @availability.root
      conversation = LiveConversation.transaction do
        LiveConversation.unfinished.for_mode(mode.key).lock.each(&:end!)
        LiveConversation.create!(
          mode: mode.key,
          agent_root: root.name,
          model: mode.model,
          status: LiveConversation::PREPARING,
          mcp_servers: Array(root.default_mcp_servers).map(&:to_s).select { |name| ServersConfig.find(name) }.uniq,
          last_activity_at: Time.current
        )
      end
      LiveConversationPrepareJob.perform_later(conversation.id)
      conversation
    rescue ActiveRecord::RecordNotUnique
      # Another start won the race for this mode's one open slot; that one is
      # the current conversation now.
      LiveConversation.current(@availability.mode.key) || raise
    end
  end
end
