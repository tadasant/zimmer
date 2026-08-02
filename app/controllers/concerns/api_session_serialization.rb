# The API's single representation of a Session.
#
# Every API response that carries a `session` key renders it through this
# concern, so `session` means one shape everywhere on the surface — a consumer
# can parse the object the same way whether it came from `GET /sessions/:id` or
# from `POST /enqueued_messages/:id/interrupt`.
#
# Usage:
#   include ApiSessionSerialization
#   render json: { session: session_json(@session) }
module ApiSessionSerialization
  extend ActiveSupport::Concern

  private

  def session_json(session, include_transcript: false)
    json = {
      id: session.id,
      slug: session.slug,
      title: session.title,
      status: session.status,
      agent_runtime: session.agent_runtime,
      prompt: session.prompt,
      git_root: session.git_root,
      branch: session.branch,
      subdirectory: session.subdirectory,
      execution_provider: session.execution_provider,
      goal: session.goal,
      mcp_servers: session.mcp_servers,
      # `mcp_servers` is only the explicitly-selected list. Consumers asking
      # "which MCP servers does this session actually have wired?" must read
      # `all_mcp_servers` — the effective set, including plugin-bundled and
      # Zimmer-auto-injected servers. `injected_mcp_servers` is the auto-injected
      # subset alone (e.g. the self-session server); on a healthy session it
      # legitimately omits every user-selected server, so it must never be read
      # as the effective set.
      all_mcp_servers: session.all_mcp_servers,
      injected_mcp_servers: session.injected_mcp_servers,
      catalog_skills: session.catalog_skills,
      catalog_hooks: session.catalog_hooks,
      catalog_plugins: session.catalog_plugins,
      config: session.config,
      metadata: session.metadata,
      custom_metadata: session.custom_metadata,
      is_autonomous: session.is_autonomous,
      heartbeat_enabled: session.heartbeat_enabled,
      heartbeat_interval_seconds: session.heartbeat_interval_seconds,
      auto_compact_window: session.auto_compact_window,
      category_id: session.category_id,
      category: category_summary(session.category),
      session_id: session.session_id,
      job_id: session.job_id,
      running_job_id: session.running_job_id,
      archived_at: session.archived_at&.iso8601,
      trash_after: session.trash_after&.iso8601,
      created_at: session.created_at.iso8601,
      updated_at: session.updated_at.iso8601
    }

    json[:session_notes] = session.session_notes
    json[:session_notes_updated_at] = session.session_notes_updated_at&.iso8601
    json[:favorited] = session.favorited
    json[:transcript] = session.transcript if include_transcript

    json
  end

  # The spawn tree a session belongs to: origin at the root, every descendant
  # below. An edge means "spawned", NOT "most recently talked to".
  #
  # A SIBLING of `session`, never a key inside it — `session` means one shape on
  # every response that carries it, a contract the API has a test for, and this
  # costs queries the index would pay once per card.
  def session_hierarchy_json(hierarchy)
    {
      origin_session_id: hierarchy.origin.id,
      truncated: hierarchy.truncated?,
      truncation_reason: hierarchy.truncation_reason,
      nodes: hierarchy.nodes.map do |node|
        {
          id: node.id,
          title: node.label,
          agent_root: node.agent_root,
          status: node.status,
          depth: node.depth,
          parent_session_id: node.parent_id,
          current: node.current?
        }
      end
    }
  end

  # What Zimmer knows a named human said anywhere in that hierarchy. `origin` is
  # the load-bearing field — `here` is a human speaking to the requested
  # session, `elsewhere` is a human speaking to another session in the tree, and
  # a consumer must not read the second as the first.
  def human_messages_json(record)
    record.entries.map do |entry|
      {
        origin: entry.origin.to_s,
        author: entry.author,
        author_display_name: entry.display_name,
        channel: entry.channel,
        channel_label: entry.channel_label,
        authored_in_session_id: entry.session_id,
        authored_in: entry.authored_in,
        entry_point: entry.entry_point,
        content: entry.content,
        occurred_at: entry.occurred_at.iso8601
      }
    end
  end

  # Compact representation of the session's category (nil when Uncategorized).
  def category_summary(category)
    return nil unless category

    {
      id: category.id,
      name: category.name,
      position: category.position,
      is_frozen: category.is_frozen
    }
  end
end
