# frozen_string_literal: true

module LiveConversations
  # Start a fresh conversation, ending the one that was open — Live Mode has one
  # current thread. It starts typed or spoken (`mode_key`) and can switch either
  # way later. The new conversation is `preparing` until
  # LiveConversationPrepareJob has read its root's AGENTS.md.
  class Start
    class Unavailable < StandardError; end

    # @param client_surface [String, nil] the TurnSource surface of the client
    #   starting it (web, ios, carplay, mcp), so a delegation the live model makes
    #   can say where the person was.
    def self.call(mode_key = "text", client_surface: nil) = new(mode_key, client_surface:).call

    def initialize(mode_key, client_surface: nil)
      @mode = LiveConversations.mode(mode_key)
      @client_surface = LiveConversation.normalize_client_surface(client_surface)
      @availability = Availability.current
    end

    # @return [LiveConversation]
    # @raise [Unavailable] with a message naming what is missing
    # @raise [KeyError] for a mode that is neither text nor voice
    def call
      raise Unavailable, @availability.reasons.join(" ") unless @availability.available?

      root = @availability.root
      conversation = LiveConversation.transaction do
        LiveConversation.unfinished.lock.each(&:end!)
        LiveConversation.create!(
          mode: @mode.key,
          agent_root: root.name,
          model: @mode.model,
          status: LiveConversation::PREPARING,
          mcp_servers: Array(root.default_mcp_servers).map(&:to_s).select { |name| ServersConfig.find(name) }.uniq,
          last_activity_at: Time.current,
          client_surface: @client_surface
        )
      end
      LiveConversationPrepareJob.perform_later(conversation.id)
      conversation
    rescue ActiveRecord::RecordNotUnique
      # Another start won the race for the one open slot; that one is the
      # current conversation now.
      LiveConversation.current || raise
    end
  end
end
