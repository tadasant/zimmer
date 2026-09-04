# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class SessionContentSearchTest < ActiveSupport::TestCase
  setup do
    # Three sessions whose ONLY distinguishing text is buried in the transcript, so
    # nothing here can pass on a title match by accident.
    @old = create_session(title: "alpha", said: "the mitochondrion is the powerhouse", created_at: 3.days.ago)
    @middle = create_session(title: "beta", said: "nothing to see", created_at: 2.days.ago)
    @new = create_session(title: "gamma", said: "the mitochondrion again", created_at: 1.day.ago)
    @scope = Session.where(id: [ @old.id, @middle.id, @new.id ])
  end

  test "matches transcript text that no other column carries" do
    result = search("mitochondrion")

    assert_equal [ @new.id, @old.id ], result.matched_ids
    assert result.complete?
    assert_not result.timed_out?
    assert_nil result.next_cursor
    assert_equal 3, result.candidate_count
  end

  test "still matches title and metadata, so it is a superset of the cheap search" do
    assert_equal [ @middle.id ], search("beta").matched_ids
  end

  test "results come back newest first" do
    result = search("mitochondrion")

    assert_equal [ @new.id, @old.id ], result.matched_ids,
      "the scan walks newest-first, and the result order must agree with the cursor it hands back"
  end

  test "stops at the limit and hands back a cursor to resume from" do
    result = search("mitochondrion", limit: 1, chunk_size: 1)

    assert_equal [ @new.id ], result.matched_ids
    assert_not result.complete?
    assert_not result.timed_out?
    assert_equal 1, result.scanned
    assert result.next_cursor.present?

    resumed = search("mitochondrion", limit: 5, chunk_size: 1, cursor: result.next_cursor)

    assert_equal [ @old.id ], resumed.matched_ids
    assert resumed.complete?, "resuming past the last candidate must report a complete scan"
    assert_nil resumed.next_cursor
  end

  test "a page that fills mid-chunk resumes at the last match shown, not past the chunk" do
    # One chunk holds all three candidates, and two of them match. Reporting only the
    # first while resuming past the whole chunk would silently lose the second.
    result = search("mitochondrion", limit: 1, chunk_size: 100)

    assert_equal [ @new.id ], result.matched_ids
    assert_not result.complete?, "a truncated page is not a complete scan"
    assert_equal SessionContentSearch.encode_cursor(@new.created_at, @new.id), result.next_cursor

    resumed = search("mitochondrion", limit: 5, chunk_size: 100, cursor: result.next_cursor)

    assert_equal [ @old.id ], resumed.matched_ids
    assert resumed.complete?
  end

  test "a cursor never re-reports a session already scanned" do
    first = search("mitochondrion", limit: 1, chunk_size: 1)
    second = search("mitochondrion", limit: 5, chunk_size: 1, cursor: first.next_cursor)

    assert_empty(first.matched_ids & second.matched_ids)
  end

  test "an unparseable cursor is ignored rather than raising" do
    result = search("mitochondrion", cursor: "not-a-cursor")

    assert_equal [ @new.id, @old.id ], result.matched_ids
  end

  test "a cursor whose id is outside bigint range is ignored, not handed to Postgres" do
    # Integer() parses a bignum happily; the adapter's quoting then raises
    # IntegerOutOf64BitRange deep in the query, which is a 500 for a malformed cursor.
    assert_nil SessionContentSearch.decode_cursor("2026-01-01T00:00:00Z|99999999999999999999")

    result = search("mitochondrion", cursor: "2026-01-01T00:00:00Z|99999999999999999999")

    assert_equal [ @new.id, @old.id ], result.matched_ids
  end

  test "a candidate list cut off by MAX_CANDIDATES is not reported as a complete scan" do
    # Without this, `scanned >= candidates.size` is true of a list that was itself
    # truncated, so the caller is told "these are every match" about a corpus the scan
    # never reached the end of — with no cursor to resume from.
    SessionContentSearch.stubs(:max_candidates).returns(2)

    result = search("mitochondrion", limit: 25)

    assert_equal 2, result.candidate_count
    assert_not result.complete?, "a capped candidate list leaves older sessions unexamined"
    assert result.next_cursor.present?, "and the caller needs a way to reach them"
  end

  test "a spent time budget returns the matches found so far, never an exception" do
    # A budget already gone by the time the first chunk is considered.
    result = SessionContentSearch.new(
      scope: @scope, query: "mitochondrion", limit: 5, budget_seconds: 0, chunk_size: 1
    ).call

    assert_empty result.matched_ids
    assert_not result.complete?
    assert result.timed_out?, "the budget, not the page size, is why this stopped"
    assert_equal 0, result.scanned
  end

  test "a statement cancelled by the server is reported, not raised" do
    SessionContentSearch.any_instance.stubs(:matching_ids).raises(ActiveRecord::QueryCanceled.new("timeout"))

    result = search("mitochondrion")

    assert_empty result.matched_ids
    assert result.timed_out?
    assert_not result.complete?
    assert_nil result.next_cursor,
      "nothing was scanned, so there is no new resume point to invent"
  end

  test "a cancellation partway through keeps the chunks that already succeeded" do
    SessionContentSearch.any_instance.stubs(:matching_ids)
      .returns(Set[@new.id]).then.raises(ActiveRecord::QueryCanceled.new("timeout"))

    result = search("mitochondrion", limit: 5, chunk_size: 1)

    assert_equal [ @new.id ], result.matched_ids
    assert result.timed_out?
    assert_equal 1, result.scanned
    assert_equal SessionContentSearch.encode_cursor(@new.created_at, @new.id), result.next_cursor
  end

  test "restores statement_timeout even when the scan raises" do
    SessionContentSearch.any_instance.stubs(:matching_ids).raises(RuntimeError, "boom")

    assert_raises(RuntimeError) { search("mitochondrion") }

    assert_equal "0", Session.connection.select_value("SHOW statement_timeout").to_s.delete_suffix("ms"),
      "the connection must be handed back with the default timeout, not this search's"
  end

  test "no candidates is a complete scan, not an inconclusive one" do
    result = SessionContentSearch.new(scope: Session.none, query: "mitochondrion").call

    assert_empty result.matched_ids
    assert result.complete?
    assert_equal 0, result.candidate_count
  end

  test "LIKE wildcards in the query are matched literally" do
    literal = create_session(title: "delta", said: "100% done", created_at: 4.hours.ago)
    scope = Session.where(id: [ literal.id, @new.id ])

    assert_equal [ literal.id ],
      SessionContentSearch.new(scope: scope, query: "100% done").call.matched_ids,
      "a literal % in the query must still find the literal % in the transcript"
    assert_empty SessionContentSearch.new(scope: scope, query: "100%done").call.matched_ids,
      "% must not act as a wildcard for the caller"
    assert_empty SessionContentSearch.new(scope: scope, query: "100%_done").call.matched_ids,
      "_ must not act as a wildcard for the caller"
  end

  test "a multi-word query is one phrase, not a loose OR over its words" do
    phrase = create_session(title: "epsilon", said: "the YC interview went well", created_at: 5.hours.ago)
    apart = create_session(title: "zeta", said: "the interview is at YC tomorrow", created_at: 6.hours.ago)
    scope = Session.where(id: [ phrase.id, apart.id ])

    assert_equal [ phrase.id ],
      SessionContentSearch.new(scope: scope, query: "YC interview").call.matched_ids,
      "a session carrying both words apart does not carry the phrase; returning it turns a two-word " \
      "search into a shortlist the caller has to re-grep by hand (#405)"
    assert_empty SessionContentSearch.new(scope: scope, query: "interview YC").call.matched_ids,
      "the words have to be adjacent AND in order — the query is one substring, not a set"
    assert_equal [ phrase.id, apart.id ],
      SessionContentSearch.new(scope: scope, query: "interview").call.matched_ids,
      "one word still matches wherever it appears, newest first"
  end

  test "eager-loaded associations on the caller's scope do not leak into the id pluck" do
    scope = Session.includes(:category).where(id: [ @old.id, @new.id ])

    assert_equal [ @new.id, @old.id ],
      SessionContentSearch.new(scope: scope, query: "mitochondrion").call.matched_ids
  end

  test "cursor round-trips a timestamp and id" do
    at = Time.zone.parse("2026-08-30T12:34:56.789012Z")
    token = SessionContentSearch.encode_cursor(at, 42)

    decoded = SessionContentSearch.decode_cursor(token)

    assert_equal 42, decoded.last
    assert_in_delta at.to_f, decoded.first.to_f, 0.000_01
  end

  private

  def search(query, limit: 25, cursor: nil, chunk_size: nil)
    SessionContentSearch.new(
      scope: @scope, query: query, limit: limit, cursor: cursor, chunk_size: chunk_size
    ).call
  end

  def create_session(title:, said:, created_at:)
    Session.create!(
      title: title,
      prompt: "prompt",
      git_root: "https://github.com/test/repo.git",
      agent_runtime: "claude_code",
      status: :needs_input,
      created_at: created_at,
      transcript: [ { "type" => "assistant", "message" => { "role" => "assistant", "content" => said } } ]
    )
  end
end
