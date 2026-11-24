# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# `events/poll` over the event log: filters, cursors, paging, truncation.
class SessionEvents::FeedTest < ActiveSupport::TestCase
  setup do
    # A test's rows sit in its own open transaction, which the feed rightly never
    # serves from; see FeedVisibilityTest for that half.
    @txid = SessionEvent.connection.select_value("SELECT pg_current_xact_id()::text::bigint").to_i
    @horizon = [ @txid + 1, 0 ]
    SessionEvents::Feed.any_instance.stubs(:visible_horizon).returns(@horizon)
    @session = create_session
  end

  def create_session(**attrs)
    Session.create!(agent_runtime: "claude_code", prompt: "work", git_root: "https://github.com/test/repo.git", branch: "main", title: "worker", **attrs)
  end

  def poll(name: SessionEvents::MESSAGE, readable: ->(_root) { true }, now: Time.current, **params)
    SessionEvents::Feed.poll({ name: name, **params }, readable: readable, now: now)
  end

  # A cursor from before anything a test writes.
  def from_the_start(now: Time.current) = "1.1.0.#{now.to_i}"

  def say(text, session: @session, reason: "update")
    SessionEvents::Publish.message(session, reason: reason, message: text)
  end

  test "a null cursor means from now: no events, and a cursor that serves only what comes after" do
    say "before"
    first = poll(cursor: nil)
    assert_empty first[:events]
    assert_not first[:truncated]

    # "After" is a later transaction.
    say("after").update_columns(txid: @txid + 1)
    SessionEvents::Feed.any_instance.stubs(:visible_horizon).returns([ @txid + 2, 0 ])
    assert_equal [ "after" ], poll(cursor: first[:cursor])[:events].map { |event| event[:data]["message"] }
  end

  test "an occurrence is one Zimmer's own events client accepts" do
    say "hello"
    raw = JSON.parse(poll(cursor: from_the_start)[:events].sole.to_json)
    occurrence = McpEvents::Client.occurrence_from(raw)

    assert_equal "session.message", occurrence.name
    assert_equal "hello", occurrence.data["message"]
    assert_equal @session.id, occurrence.data["sessionId"]
  end

  test "pages with hasMore and serves each event exactly once" do
    5.times { |i| say "m#{i}" }
    seen = []
    cursor = from_the_start
    pages = 0
    loop do
      result = poll(cursor: cursor, maxEvents: 2)
      seen.concat(result[:events].map { |event| event[:data]["message"] })
      cursor = result[:cursor]
      pages += 1
      break unless result[:hasMore]
    end

    assert_equal %w[m0 m1 m2 m3 m4], seen
    assert_equal 3, pages
    assert_empty poll(cursor: cursor)[:events]
  end

  test "filters by session, parent, reason and state" do
    parent = create_session
    child = create_session(parent_session_id: parent.id)
    say "mine"
    say "the child's", session: child, reason: "done"
    SessionEvents::Publish.state_changed(child, state: "archived", key: "k")
    SessionEvents::Publish.state_changed(child, state: "failed", key: "k")

    messages = ->(arguments) { poll(cursor: from_the_start, arguments: arguments)[:events].map { |event| event[:data]["message"] } }
    assert_equal [ "mine" ], messages.({ session_id: @session.id })
    assert_equal [ "the child's" ], messages.({ parent_session_id: parent.id })
    assert_equal [ "the child's" ], messages.({ reason: "done" })
    states = poll(name: SessionEvents::STATE_CHANGED, cursor: from_the_start, arguments: { state: "failed" })[:events]
    assert_equal [ "failed" ], states.map { |event| event[:data]["state"] }
  end

  test "serves only the roots the caller may read, and still moves past the rest" do
    say "hidden"
    result = poll(cursor: from_the_start, readable: ->(root) { root == "zimmer" })
    assert_empty result[:events]
    assert_empty poll(cursor: result[:cursor])[:events]
  end

  test "a cursor older than the log, or past the database's transactions, is truncated and reset" do
    say "kept"
    old = poll(cursor: from_the_start(now: 20.days.ago))
    assert old[:truncated]
    assert_empty old[:events]

    ahead = poll(cursor: "1.#{@txid + 1_000_000}.0.#{Time.current.to_i}")
    assert ahead[:truncated]
    assert_equal "1.#{@horizon.first}", ahead[:cursor].split(".").first(2).join(".")
  end

  test "maxAgeMs starts later than the cursor and says so when it skipped something" do
    say("old").update_columns(occurred_at: 1.hour.ago)
    say "new"
    result = poll(cursor: from_the_start, maxAgeMs: 60_000)
    assert_equal [ "new" ], result[:events].map { |event| event[:data]["message"] }
    assert result[:truncated]
    assert_not poll(cursor: from_the_start, maxAgeMs: 7_200_000)[:truncated]
  end

  test "refuses an unknown event, argument, value or cursor with the extension's error" do
    { not_found: { name: "nope" },
      invalid_params: { arguments: { wat: 1 } } }.each do |code, params|
      error = assert_raises(SessionEvents::Feed::Refused) { poll(cursor: nil, **params) }
      assert_equal code, error.code
    end
    [ { arguments: { reason: "nope" } }, { arguments: { session_id: "7" } }, { arguments: [] }, { maxEvents: 0 },
      { maxAgeMs: -1, cursor: from_the_start } ].each do |params|
      assert_equal :invalid_params, assert_raises(SessionEvents::Feed::Refused) { poll(**{ cursor: nil }.merge(params)).then { poll(cursor: from_the_start, **params.except(:cursor)) } }.code
    end
    assert_equal :invalid_params, assert_raises(SessionEvents::Feed::Refused) { poll(cursor: "garbage") }.code
  end

  test "a long message is cut in the payload and marked" do
    say "x" * (SessionEvents::MESSAGE_LIMIT + 1)
    data = poll(cursor: from_the_start)[:events].sole[:data]
    assert data["messageTruncated"]
    assert_operator data["message"].length, :<=, SessionEvents::MESSAGE_LIMIT
  end

  test "publishing one transition twice writes it once" do
    assert SessionEvents::Publish.state_changed(@session, state: "failed", key: "abc")
    assert_nil SessionEvents::Publish.state_changed(@session, state: "failed", key: "abc")
    assert_equal 1, SessionEvent.where(session: @session, name: SessionEvents::STATE_CHANGED).count
  end
end

# The half of the cursor that needs real transactions: a writer that has not
# committed is never stepped over.
class SessionEvents::FeedVisibilityTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  test "a cursor issued while a writer is open stays behind that writer's row" do
    session = Session.create!(agent_runtime: "claude_code", prompt: "work", git_root: "https://github.com/test/repo.git", branch: "main", title: "worker")
    cursor = nil
    written = nil
    SessionEvent.transaction do
      written = SessionEvents::Publish.message(session, reason: "update", message: "late").reload
      cursor = Thread.new { ActiveRecord::Base.connection_pool.with_connection { SessionEvents::Feed.poll({ name: SessionEvents::MESSAGE }, readable: ->(_) { true })[:cursor] } }.value
    end

    position = cursor.split(".")[1, 2].map(&:to_i)
    assert_operator position <=> [ written.txid, written.id ], :<, 0
  ensure
    session&.destroy
  end
end
