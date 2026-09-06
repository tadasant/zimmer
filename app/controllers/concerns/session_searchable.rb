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

  # PostgreSQL: the JSON/JSONB columns are matched as text, ILIKE for
  # case-insensitivity. Both predicates take the same two binds, and
  # `SessionSearchable.search_binds` is the only place that builds them.
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
  # What the transcript half matches is the stored JSONL, not the rendered
  # conversation: a hit can land in a tool argument or a file path rather than in
  # anything anybody said. The two storages differ in one way worth knowing, and it
  # is the `json` column's doing rather than the chunk table's: `transcript::text`
  # renders the column as a JSON *string literal*, so the document arrives quoted
  # and escaped and a query containing a `"` matches the `\"` in it. The chunk half
  # is the raw JSONL, where a `"` is a `"`. That makes the chunk half the more
  # truthful of the two, and it stops being a difference at all once
  # `BackfillSessionTranscriptChunks` has emptied the column.
  #
  # Both JSON columns are read through `::jsonb::text`, never `::text` directly.
  # `metadata` is a `json` column and `custom_metadata` a `jsonb` one, and on `json`
  # that difference decided what a query matched: `json` keeps the writer's bytes
  # verbatim, so one row rendered two ways depending on who wrote it last. An ordinary
  # attribute write emits `{"agent_root_key":"zimmer-router"}`; the atomic
  # `merge_metadata!` UPDATE computes in jsonb and casts back, emitting
  # `{"agent_root_key": "zimmer-router"}`. Both writers are on the hot path, so a query
  # spanning a structural colon found a session or did not depending on which one had
  # touched it most recently — the same query, seconds apart, returning different sets,
  # with no signal that the answer was partial (#930). `::jsonb::text` renders
  # Postgres's canonical form whatever the writer did. It is a no-op for
  # `custom_metadata`, already jsonb, and stays one when `metadata` becomes jsonb (#847).
  #
  # The cast normalises more than spacing: `1e2` becomes `100`, an escaped unicode
  # sequence becomes the character it names, `\/` becomes `/`, a pretty-printed blob
  # collapses, and duplicate keys collapse to the last — which is the one Rails hands
  # back on read anyway. Every one of those makes matching more truthful, not less.
  #
  # It also REORDERS an object's keys, by length then bytewise, and that is the one
  # thing canonicalising takes away. A fragment spanning the comma BETWEEN two keys now
  # matches only if the caller happened to spell them in Postgres's order, so search one
  # key/value pair, or a value, rather than two pairs in a row. That fragment was never
  # dependable — before this change it matched or not depending on the writer — but it
  # is now dependably one way, which is worth stating rather than leaving as a surprise.
  # docs/src/content/docs/limitations.md says it where callers read.
  #
  # The cast cannot fail on a `metadata` row, and the reason is an index rather than the
  # type. `jsonb` rejects a `\u0000` inside a string where `json` accepts it happily — but
  # `index_sessions_on_agent_root_key` is an unconditional expression index over
  # `metadata ->> 'agent_root_key'`, and `->>` rejects that byte too, so every write to
  # this column already has to survive the same check. Drop or narrow that index and
  # this guarantee goes with it.
  #
  # `transcript` is deliberately NOT canonicalised, for two reasons, and the second is
  # the one that bites. Parsing a multi-megabyte document into jsonb per row would spend
  # exactly the budget SessionContentSearch's bound exists to protect — and `transcript`
  # carries no expression index, so unlike `metadata` it CAN hold a `\u0000`: an ordinary
  # attribute write stores one without complaint, and `transcript::jsonb` would then
  # raise `PG::UntranslatableCharacter` on every content search, across all three
  # surfaces, for as long as that one session existed.
  METADATA_PREDICATE = <<~SQL.squish
    title ILIKE :q
    OR metadata::jsonb::text ILIKE ANY (ARRAY[:q, :q_json])
    OR custom_metadata::jsonb::text ILIKE ANY (ARRAY[:q, :q_json])
  SQL
  # The transcript half reaches both storages, because until
  # `BackfillSessionTranscriptChunks` has emptied the legacy column a session's
  # conversation may be in either one (#110). `EXISTS` over the chunk table rather
  # than a join, so a session with 128 matching chunks is one row and one match.
  #
  # Chunk boundaries are cut at line breaks (SessionTranscriptChunk, invariant 1),
  # so the only phrase a per-chunk match can miss is one spanning the newline
  # BETWEEN two JSON events — text nobody typed, since that newline is a record
  # separator. A phrase inside an event is inside one chunk by construction.
  TRANSCRIPT_PREDICATE = <<~SQL.squish
    transcript::text ILIKE :q
    OR EXISTS (
      SELECT 1 FROM session_transcript_chunks stc
      WHERE stc.session_id = sessions.id AND stc.content ILIKE :q
    )
  SQL
  CONTENT_PREDICATE = "#{METADATA_PREDICATE} OR #{TRANSCRIPT_PREDICATE}"

  # `:q_json` is `:q` respelled in the spacing Postgres itself uses, so a caller who
  # typed compact JSON finds the same rows as one who copied the pretty-printed blob
  # out of `get_session`. Canonicalising the column decides which single text is
  # searched; it does not make the other spelling of the query mean anything, and a
  # `"key":"value"` that consistently returns nothing is the same silent zero #930 is
  # about — one that `custom_metadata`, jsonb since the day it was added, has always
  # returned.
  #
  # Canonical jsonb puts one space after every `:` and every `,`. Every structural colon
  # is preceded by a closing quote, since a JSON key is always a string, so `":` finds
  # them and leaves `https://…` alone. The converse is very nearly true rather than
  # exactly: an escaped quote inside a value matches too. That only widens the pattern —
  # `:q_json` is an extra alternative, never a replacement — so a miss here costs
  # nothing, which is why the cheap rule is the right one.
  #
  # This is the SAME phrase spelled twice, not a set of per-word ORs (#405): adjacency
  # and order still hold, and the rewritten pattern is a whole substring like the
  # original. Only the JSON columns get it; `title` and `transcript` bind `:q` alone.
  JSON_KEY_COLON = /":(?! )/
  JSON_COMMA = /,(?! )/

  # The binds every caller of the two predicates passes. One place builds them, for
  # the same reason one place spells the predicates.
  def self.search_binds(query)
    pattern = "%#{ActiveRecord::Base.sanitize_sql_like(query)}%"
    { q: pattern, q_json: pattern.gsub(JSON_KEY_COLON, '": ').gsub(JSON_COMMA, ", ") }
  end

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
    sessions.where(METADATA_PREDICATE, SessionSearchable.search_binds(query))
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
