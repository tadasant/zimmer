# Shared concern for session search functionality.
#
# Provides PostgreSQL-based search across session title, metadata, custom_metadata,
# and optionally transcript content.
#
# Usage:
#   include SessionSearchable
#   sessions = filter_sessions_by_search(Session.all, "query", include_contents: true)
module SessionSearchable
  extend ActiveSupport::Concern

  private

  # Filter sessions by search query.
  #
  # Searches title and metadata by default, optionally includes transcript content.
  # Uses PostgreSQL ILIKE for case-insensitive search and ::text casting for JSON columns.
  #
  # @param sessions [ActiveRecord::Relation] The scope to filter
  # @param query [String] The search query
  # @param include_contents [Boolean] Whether to search transcript content (default: false)
  # @return [ActiveRecord::Relation] Filtered sessions
  def filter_sessions_by_search(sessions, query, include_contents: false)
    # Sanitize LIKE wildcards and create search term
    sanitized_query = ActiveRecord::Base.sanitize_sql_like(query)
    search_term = "%#{sanitized_query}%"

    # PostgreSQL: Use ::text casting for JSON/JSONB columns and ILIKE for case-insensitive
    if include_contents
      sessions.where(
        "title ILIKE :q OR metadata::text ILIKE :q OR custom_metadata::text ILIKE :q OR transcript::text ILIKE :q",
        q: search_term
      )
    else
      sessions.where(
        "title ILIKE :q OR metadata::text ILIKE :q OR custom_metadata::text ILIKE :q",
        q: search_term
      )
    end
  end

  # Filter sessions down to those belonging to a single agent root.
  #
  # Mirrors AgentRootsConfig.find_for_session, which is metadata-key-wins-with-fallback:
  # the explicit agent_root_key in metadata takes precedence, and the git_root URL +
  # subdirectory are only consulted when that key is absent/blank. The URL+subdirectory
  # fallback keeps the filter robust for older sessions created before agent_root_key was
  # persisted in metadata. Gating the fallback on a blank key (rather than OR-ing the two
  # unconditionally) means a session whose key points at a different root is never
  # surfaced under this root just because its URL columns happen to match — exactly as
  # find_for_session would resolve it.
  #
  # The one residual divergence from find_for_session: if a session's key is present but
  # unresolvable (points at a root not in the catalog), find_for_session falls back to
  # URL+subdirectory whereas this filter does not. That requires a session carrying a
  # stale/garbage agent_root_key, which the normal creation path cannot produce (it sets
  # git_root, subdirectory, and agent_root_key from the same agent root).
  #
  # An unrecognized root name matches nothing (returns an empty scope) rather than
  # silently returning all sessions.
  #
  # @param sessions [ActiveRecord::Relation] The scope to filter
  # @param root_name [String] The agent root's catalog name (e.g. "zimmer")
  # @return [ActiveRecord::Relation] Filtered sessions
  def filter_sessions_by_agent_root(sessions, root_name)
    root = AgentRootsConfig.find(root_name)
    return sessions.none unless root

    sessions.where(
      "metadata->>'agent_root_key' = :name " \
      "OR (COALESCE(metadata->>'agent_root_key', '') = '' " \
      "AND git_root = :url AND COALESCE(subdirectory, '') = :subdir)",
      name: root.name, url: root.url, subdir: root.subdirectory.to_s
    )
  end
end
