# Shared concern for session search functionality.
#
# One search, three surfaces: the dashboard (SessionsController), the REST API
# (Api::V1::SessionsController#search) and MCP (Mcp::Tools::QuickSearchSessions).
# They must agree about what a query matches, so the predicates live here as
# constants and nobody re-spells them.
#
# Two searches, though, not one shape:
#
#   filter_sessions_by_search  the cheap one. Title + metadata + custom_metadata,
#                              all small columns. Composes as a relation, so callers
#                              paginate and order it however they like.
#
#   search_sessions_by_content the expensive one. Also matches `transcript`, a `json`
#                              column with no usable index — see SessionContentSearch
#                              for why that has to be bounded and how. It returns a
#                              relation *plus* a scan report, because a bounded search
#                              owes the caller an answer to "did you look everywhere?".
#
# `filter_sessions_by_search` deliberately has no `include_contents:` switch any more.
# The unbounded transcript scan it used to hide behind that keyword is the query that
# 504s (#405), and the way to make sure no surface takes it by accident is for it not
# to exist.
#
# Usage:
#   include SessionSearchable
#   sessions = filter_sessions_by_search(Session.all, "query")
#   sessions, scan = search_sessions_by_content(Session.all, "query", limit: 25)
module SessionSearchable
  extend ActiveSupport::Concern

  # PostgreSQL: `::text` casting for the JSON/JSONB columns, ILIKE for
  # case-insensitivity. Bound as `:q` by every caller.
  #
  # `:q` is the WHOLE query wrapped in one `%…%`, never a set of words, on both
  # predicates. So a multi-word query is a phrase: "YC interview" matches a title
  # (or a transcript) reading `YC interview` and not one reading `the interview is
  # at YC`. Splitting it into per-word ORs would be a wider net that reads like a
  # working search — every caller gets a shortlist to re-grep by hand instead of an
  # answer (#405). Adjacency and order are the contract, pinned for the cheap path
  # in Api::V1::SessionsControllerTest and for the transcript in
  # SessionContentSearchTest.
  #
  # What `transcript::text` matches is the stored JSON, not the rendered
  # conversation: a phrase broken across a line break is `\n` in that text and does
  # not match, and a hit can land in a tool argument or a file path rather than in
  # anything anybody said.
  METADATA_PREDICATE = "title ILIKE :q OR metadata::text ILIKE :q OR custom_metadata::text ILIKE :q"
  CONTENT_PREDICATE = "#{METADATA_PREDICATE} OR transcript::text ILIKE :q"

  # Does this parameter value mean "yes, search transcript contents"?
  #
  # The dashboard's checkbox posts "1" and the REST API documented "true", and the two
  # readers used to compare against their own literal — so a caller who copied the URL
  # out of the browser got a silent title-only search from the API, with a 200 and no
  # hint that the flag had been ignored. One reader, both spellings, everywhere.
  def self.search_contents?(value)
    ActiveModel::Type::Boolean.new.cast(value) == true
  end

  private

  # Filter sessions by search query across title, metadata and custom_metadata.
  #
  # @param sessions [ActiveRecord::Relation] The scope to filter
  # @param query [String] The search query
  # @return [ActiveRecord::Relation] Filtered sessions
  def filter_sessions_by_search(sessions, query)
    sessions.where(METADATA_PREDICATE, q: "%#{ActiveRecord::Base.sanitize_sql_like(query)}%")
  end

  # Filter sessions by search query, transcript contents included.
  #
  # Bounded by wall clock and resumable by cursor — see SessionContentSearch. The
  # returned relation carries only the ids the scan matched, so the caller can order
  # and render it like any other scope; the returned Result says how far the scan got
  # and where to resume.
  #
  # @return [Array(ActiveRecord::Relation, SessionContentSearch::Result)]
  def search_sessions_by_content(sessions, query, limit: SessionContentSearch::DEFAULT_LIMIT, cursor: nil)
    result = SessionContentSearch.new(scope: sessions, query: query, limit: limit, cursor: cursor).call
    [ sessions.where(id: result.matched_ids), result ]
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
