# frozen_string_literal: true

require "test_helper"

# #930: a metadata query returned different sets seconds apart, and the omissions were
# false negatives on sessions that plainly matched. The cause is that `sessions.metadata`
# is a `json` column, which stores the writer's bytes verbatim — so the same logical
# blob rendered two ways depending on which of the app's two writers touched the row
# last. These tests pin the two properties that failure violated: the rendering the
# search reads is the same whoever wrote the row, and both spellings of a JSON query
# find it.
class SessionSearchableTest < ActiveSupport::TestCase
  include SessionSearchable

  ROOT_KEY = "zimmer-router"
  SPACED = %("agent_root_key": "#{ROOT_KEY}")
  COMPACT = %("agent_root_key":"#{ROOT_KEY}")

  # The two writers, both on the hot path. `create!` goes through the attribute type,
  # which serialises compactly; `merge_metadata!` computes in jsonb and casts back,
  # which serialises canonically. Nothing else about the rows differs.
  def session_written_by_active_record
    build_session.tap { |s| s.update!(metadata: { "agent_root_key" => ROOT_KEY }) }
  end

  def session_written_by_atomic_merge
    build_session.tap { |s| s.merge_metadata!("agent_root_key" => ROOT_KEY) }
  end

  # Every session this file makes is remembered, and every search runs against only
  # those — a fixture that happened to carry one of these phrases would otherwise turn
  # an exact-set assertion into a coin flip.
  def build_session(**attrs)
    Session.create!(
      prompt: "p", git_root: "https://github.com/test/repo.git", branch: "main",
      agent_runtime: "claude_code", status: :running, **attrs
    ).tap { |s| created_ids << s.id }
  end

  def created_ids
    @created_ids ||= []
  end

  def search(query)
    filter_sessions_by_search(Session.where(id: created_ids), query).pluck(:id)
  end

  def stored_metadata_text(session)
    Session.connection.select_value(
      Session.sanitize_sql_array([ "SELECT metadata::text FROM sessions WHERE id = ?", session.id ])
    )
  end

  test "the two writers really do store different bytes for the same metadata" do
    # If this ever stops being true the rest of the file is testing nothing, so assert
    # the premise rather than trusting it.
    by_active_record = stored_metadata_text(session_written_by_active_record)
    by_merge = stored_metadata_text(session_written_by_atomic_merge)

    assert_includes by_active_record, COMPACT
    assert_not_includes by_active_record, SPACED
    assert_includes by_merge, SPACED
    assert_not_includes by_merge, COMPACT
  end

  test "a key/value query finds a row whichever writer serialised it" do
    by_active_record = session_written_by_active_record
    by_merge = session_written_by_atomic_merge

    assert_equal [ by_active_record.id, by_merge.id ].sort, search(SPACED).sort
    assert_equal [ by_active_record.id, by_merge.id ].sort, search(COMPACT).sort
  end

  test "a session does not vanish from its own query when another writer touches it" do
    # Observation 2 in #930: the session had appeared in this exact query twenty
    # minutes earlier and nothing about it had changed except who wrote it last.
    session = session_written_by_atomic_merge
    assert_includes search(SPACED), session.id

    session.update!(metadata: session.metadata.merge("clone_path" => "/tmp/clone"))
    assert_includes search(SPACED), session.id, "an ordinary attribute write must not hide the row"

    session.merge_metadata!("heartbeat_last" => "now")
    assert_includes search(SPACED), session.id, "an atomic merge must not hide the row either"
  end

  test "custom_metadata answers both spellings too" do
    session = build_session(custom_metadata: { "tracking_issue" => "https://github.com/tadasant/zimmer/issues/930" })

    assert_includes search(%("tracking_issue": "https://github.com/tadasant/zimmer/issues/930")), session.id
    assert_includes search(%("tracking_issue":"https://github.com/tadasant/zimmer/issues/930")), session.id
  end

  test "a nested value and an array match in either spelling" do
    session = build_session(custom_metadata: {
      "github_pull_request_urls" => [ "https://github.com/tadasant/zimmer/pull/1", "https://github.com/tadasant/zimmer/pull/2" ]
    })

    assert_includes search(%(/pull/1", "https://github.com/tadasant/zimmer/pull/2)), session.id
    assert_includes search(%(/pull/1","https://github.com/tadasant/zimmer/pull/2)), session.id
  end

  # #405: the query is one substring, never a set of per-word ORs. The respelling adds
  # a second spelling of the same phrase, not a second phrase.
  test "phrase semantics survive the respelling" do
    session = build_session(title: "YC interview", metadata: { "note" => "the interview is at YC" })

    assert_includes search("YC interview"), session.id
    assert_not_includes search("interview YC"), session.id
    assert_not_includes search("YC at"), session.id
  end

  test "a query that matches nothing still matches nothing" do
    session_written_by_atomic_merge
    session_written_by_active_record

    assert_empty search(%("agent_root_key": "zimmer-orchestrator"))
    assert_empty search(%("agent_root_key":"zimmer-orchestrator"))
  end

  test "search_binds respells structural JSON spacing and leaves everything else alone" do
    binds = SessionSearchable.search_binds(%("root":"zimmer"))
    assert_equal %(%"root":"zimmer"%), binds[:q]
    assert_equal %(%"root": "zimmer"%), binds[:q_json]

    # A URL's colon is not a JSON key's colon: it is not preceded by a closing quote.
    url = "https://github.com/tadasant/zimmer/issues/930"
    assert_equal "%#{url}%", SessionSearchable.search_binds(url)[:q_json]

    # Already-canonical input is left exactly as it is.
    assert_equal %(%"root": "zimmer"%), SessionSearchable.search_binds(%("root": "zimmer"))[:q_json]

    # LIKE metacharacters are still escaped, and the respelling does not disturb them.
    assert_equal %(%a\\%b\\_c%), SessionSearchable.search_binds("a%b_c")[:q_json]
  end
end
