# frozen_string_literal: true

# preparing → active: read the agent root's AGENTS.md (the system prompt) and
# list the tools of every catalog server the root enables by default, so
# building the function list later never has to spawn a server. A server that
# cannot be listed is dropped from the conversation rather than failing it; a
# root whose instructions cannot be read fails it, with the reason on the page.
class LiveConversationPrepareJob < ApplicationJob
  queue_as :default

  def perform(conversation_id)
    conversation = LiveConversation.find_by(id: conversation_id)
    return unless conversation&.preparing?

    root = AgentRootsConfig.find(conversation.agent_root)
    if root.nil?
      conversation.fail!("The catalog has no `#{conversation.agent_root}` agent root.")
      return
    end

    instructions = LiveConversations::RootInstructions.fetch(root)
    servers, cache, dropped = list_tools(conversation.enabled_mcp_servers)

    conversation.update!(
      status: LiveConversation::ACTIVE,
      instructions: instructions.text,
      instructions_source: instructions.source,
      mcp_servers: servers,
      mcp_tool_cache: cache,
      error_message: dropped.any? ? "Could not enable #{dropped.join('; ')}" : nil,
      last_activity_at: Time.current
    )
    # Typed before the instructions were in: answer it now.
    LiveConversationReplyJob.perform_later(conversation.id) if conversation.text? && LiveConversations::TextReply.awaiting_reply?(conversation)
  rescue LiveConversations::RootInstructions::Error => e
    conversation&.fail!(e.message)
  end

  private

  def list_tools(names)
    servers = []
    cache = {}
    dropped = []
    names.each do |name|
      if SelfSessionInjector.zimmer_server_name?(name)
        servers << name
        next
      end

      begin
        cache[name] = LiveConversations::CatalogServer.find!(name).list_tools.map(&:to_cache_entry)
        servers << name
      rescue LiveConversations::CatalogServer::Unavailable => e
        dropped << e.message.truncate(200)
      end
    end
    [ servers, cache, dropped ]
  end
end
