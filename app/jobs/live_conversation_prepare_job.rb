# frozen_string_literal: true

# preparing → active: read the agent root's AGENTS.md (the system prompt) and
# its per-mode style files (typed, spoken), and
# list the tools of every catalog server the root enables by default, so
# building the function list later never has to spawn a server. A server that
# cannot be listed is dropped from the conversation rather than failing it; a
# root whose instructions cannot be read fails it, with the reason on the page.
#
# `refresh: true` is the same read for a conversation already active, after
# LiveConversations::Switch reopened it: instructions and tool lists catch up
# with the catalog in the background, and a read that fails changes nothing,
# because a conversation that has just come back has to keep working.
class LiveConversationPrepareJob < ApplicationJob
  queue_as :default

  # `adding`: default servers the conversation started without — a new one
  # LiveConversations::Start began from an earlier conversation's tool lists,
  # which had none for these. The refresh lists them too, and enables each one
  # that answers.
  def perform(conversation_id, refresh: false, adding: [])
    conversation = LiveConversation.find_by(id: conversation_id)
    return refresh(conversation, Array(adding).map(&:to_s)) if refresh
    return unless conversation&.preparing?

    root = AgentRootsConfig.find(conversation.agent_root)
    if root.nil?
      fail_if_preparing(conversation, "The catalog has no `#{conversation.agent_root}` agent root.")
      return
    end

    instructions = LiveConversations::RootInstructions.fetch(root)
    servers, cache, dropped = list_tools(conversation.enabled_mcp_servers)

    # Under the lock and looked at again: reading the root takes seconds, and the
    # conversation may have been left meanwhile. Activating it then would trip the
    # unique index and fail a conversation that can still be gone back to.
    activated = conversation.with_lock do
      next false unless conversation.preparing?

      conversation.update!(
        status: LiveConversation::ACTIVE,
        instructions: instructions.text,
        instructions_source: instructions.source,
        mode_instructions: instructions.modes,
        mcp_servers: servers,
        mcp_tool_cache: cache,
        error_message: dropped.any? ? "Could not enable #{dropped.join('; ')}" : nil,
        last_activity_at: Time.current
      )
      true
    end
    return unless activated

    # Typed before the instructions were in: answer it now.
    LiveConversationReplyJob.perform_later(conversation.id) if conversation.text? && LiveConversations::TextReply.awaiting_reply?(conversation)
  rescue LiveConversations::RootInstructions::Error => e
    fail_if_preparing(conversation, e.message)
  rescue StandardError => e
    # Anything else would leave the conversation `preparing` forever, with a
    # page waiting on it. Fail it with the reason, and report it.
    ErrorReporter.report_exception(e, context: { source: "LiveConversationPrepareJob", live_conversation_id: conversation_id })
    fail_if_preparing(conversation, "Could not prepare this conversation: #{e.class}: #{e.message.to_s.truncate(300)}")
  end

  private

  # `failed` is final, so it is only for a conversation still waiting on this job.
  def fail_if_preparing(conversation, message)
    conversation&.with_lock { conversation.fail!(message) if conversation.preparing? }
  end

  def refresh(conversation, adding = [])
    return unless conversation&.active?

    root = AgentRootsConfig.find(conversation.agent_root)
    return if root.nil?

    adding -= conversation.enabled_mcp_servers
    # The servers first: a root that cannot be read this time keeps the
    # instructions the conversation has, but still gains the servers that answer.
    _servers, cache, _dropped = list_tools(conversation.enabled_mcp_servers)
    added, added_cache, dropped = list_tools(adding)
    instructions = begin
      LiveConversations::RootInstructions.fetch(root)
    rescue LiveConversations::RootInstructions::Error => e
      ErrorReporter.report_exception(e, context: { source: "LiveConversationPrepareJob#refresh", live_conversation_id: conversation.id })
      nil
    end
    # Under the lock and re-read: a call can enable a server meanwhile.
    # Left meanwhile (a second New, a switch): what it ended with stays.
    conversation.with_lock do
      next unless conversation.active?

      servers = conversation.enabled_mcp_servers | added
      changes = { mcp_servers: servers, mcp_tool_cache: conversation.mcp_tool_cache.merge(cache).merge(added_cache).slice(*servers) }
      changes.merge!(instructions: instructions.text, instructions_source: instructions.source, mode_instructions: instructions.modes) if instructions
      # A default that still cannot start is said on the page, as preparing says it.
      changes[:error_message] = "Could not enable #{dropped.join('; ')}" if dropped.any? && conversation.error_message.blank?
      conversation.update!(changes)
    end
  rescue StandardError => e
    ErrorReporter.report_exception(e, context: { source: "LiveConversationPrepareJob#refresh", live_conversation_id: conversation&.id })
  end

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
