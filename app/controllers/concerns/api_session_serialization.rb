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

  # The per-genesis override map, read once per request. `session_json` is called
  # in a map over as many as 100 records, and priority_class derives rather than
  # reads a column — without this each row would re-query app_settings.
  def genesis_class_overrides
    @genesis_class_overrides ||= AppSetting.current.genesis_class_overrides || {}
  end

  def session_json(session, include_transcript: false)
    json = {
      id: session.id,
      slug: session.slug,
      title: session.title,
      status: session.status,
      agent_runtime: session.agent_runtime,
      # Where this session's line of work came from, and the scheduling class it
      # runs under. `scheduling_class` is the explicit choice made for this one
      # session and is null on most of them; `priority_class` is the answer that
      # counts — that choice when there is one, otherwise derived from the genesis
      # on read, so moving a genesis in Settings changes existing sessions too.
      genesis: session.genesis_key,
      scheduling_class: session.scheduling_class,
      priority_class: session.priority_class(genesis_class_overrides),
      # Rank within the spot queue: higher is handled sooner, absolute scale.
      precedence: session.precedence,
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

  # The cached Status blurb and how far behind the session it is.
  #
  # A SIBLING of `session` for the same reason session_hierarchy_json is: the
  # `session` object means one shape on every response that carries it. Reading
  # it never generates one — POST .../regenerate_status_summary does that.
  # `state` and `error` are reported even when there is no text yet, so a caller
  # that asked for a regeneration can tell "still running" from "never generated"
  # and "failed" without polling for text that may never arrive.
  def session_status_summary_json(session)
    record = session.status_summary
    return nil if record.nil?

    {
      summary: record.summary.presence,
      generated_at: record.generated_at&.iso8601,
      messages_since_generated: record.summary.present? ? record.messages_since(session.transcript_line_count) : nil,
      state: record.state,
      generating: record.pending?,
      error: record.error.presence
    }
  end

  # The lineage graph a session belongs to: roots at the top, every descendant
  # below. Two kinds of edge — a spawn edge (`parent_session_id`) means "spawned",
  # and an uncle edge (`uncle_session_ids`) means "queued or interrupted, and is
  # therefore senior". Neither means "most recently talked to".
  #
  # `origin_session_id` is the SPAWN origin and stays single-valued;
  # `root_session_ids` is every root the graph is drawn from, which uncle edges
  # can make more than one. A consumer reading only `origin_session_id` sees what
  # it always saw.
  #
  # A SIBLING of `session`, never a key inside it — `session` means one shape on
  # every response that carries it, a contract the API has a test for, and this
  # costs queries the index would pay once per card.
  def session_hierarchy_json(hierarchy)
    {
      origin_session_id: hierarchy.origin.id,
      root_session_ids: hierarchy.root_ids,
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
          uncle_session_ids: node.uncles,
          current: node.current?,
          genesis: node.genesis,
          priority_class: node.priority_class
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
