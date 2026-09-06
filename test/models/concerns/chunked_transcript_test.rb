# frozen_string_literal: true

require "test_helper"

# The storage half of #110: `session.transcript` reads and writes exactly as it
# always did, and underneath it is an append-only chunk table rather than one
# column that gets rewritten whole on every poll.
#
# The load-bearing assertion in almost every test here is BYTE-FOR-BYTE equality of
# what goes in and what comes back out. A transcript is the only durable record of
# a session's conversation, so "close enough" is not a passing grade: a normaliser
# that dropped a trailing newline, a chunk boundary that split a multi-byte
# character, an append that lost the seam between two events — each would be
# invisible in a test that compared parsed events instead of bytes.
class ChunkedTranscriptTest < ActiveSupport::TestCase
  setup do
    @session = create_session(prompt: "chunked transcript")
    SessionTranscriptChunk.where(session_id: @session.id).delete_all
    @session.reload
  end

  def jsonl(count, text: "event", start: 0)
    (start...(start + count)).map { |i| JSON.generate({ "type" => "assistant", "n" => i, "text" => text }) }.join("\n") + "\n"
  end

  def chunks_of(session)
    SessionTranscriptChunk.where(session_id: session.id).order(:seq).to_a
  end

  def stored_bytes(session)
    chunks_of(session).map(&:content).join
  end

  # Every SELECT issued against the chunk table while the block runs. Reads of the
  # chunk table are the cost this change exists to bound, so several tests here
  # assert on how many of them a path makes rather than only on what it returns.
  def chunk_selects_during
    statements = []
    callback = lambda do |_name, _start, _finish, _id, payload|
      sql = payload[:sql].to_s.squish
      statements << sql if sql.start_with?("SELECT") && sql.include?('"session_transcript_chunks"')
    end

    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    statements
  end

  # --- round trip ---------------------------------------------------------

  test "a transcript reads back byte for byte" do
    content = jsonl(20)
    @session.update!(transcript: content)

    assert_equal content, Session.find(@session.id).transcript
    assert_equal content, stored_bytes(@session)
    assert_equal content.bytesize, Session.find(@session.id).transcript_byte_size
    assert_equal 20, Session.find(@session.id).transcript_line_count
  end

  test "a transcript larger than one chunk reads back byte for byte" do
    content = jsonl(4_000, text: "x" * 200)
    assert_operator content.bytesize, :>, SessionTranscriptChunk::TARGET_BYTES * 3,
      "the fixture must be big enough to need several chunks"

    @session.update!(transcript: content)
    fresh = Session.find(@session.id)

    assert_operator chunks_of(@session).size, :>, 3
    assert_equal content, fresh.transcript
    assert_equal 4_000, fresh.transcript_line_count
  end

  test "multi-byte characters survive chunk boundaries" do
    # One line of roughly a chunk and a half, entirely non-ASCII, so a boundary
    # chosen by byte offset alone would land mid-character and corrupt the text.
    line = JSON.generate({ "type" => "assistant", "text" => "日本語テキスト" * 30_000 })
    content = "#{line}\n#{jsonl(3)}"

    @session.update!(transcript: content)
    fresh = Session.find(@session.id)

    assert_equal content, fresh.transcript
    assert_predicate fresh.transcript, :valid_encoding?
    chunks_of(@session).each { |chunk| assert_predicate chunk.content, :valid_encoding? }
  end

  test "an unterminated final line round-trips and counts as a line" do
    content = "#{jsonl(3)}{\"type\":\"assistant\",\"n\":3}"
    @session.update!(transcript: content)

    assert_equal content, Session.find(@session.id).transcript
    assert_equal 4, Session.find(@session.id).transcript_line_count
  end

  test "a raw NUL byte is stripped rather than raising" do
    # The old `json` column encoded 0x00 as the escape `\u0000` and Postgres never
    # saw the byte; `text` does, and rejects it. An agent that prints one would
    # otherwise raise inside the poll's own transaction and freeze this session's
    # transcript for good.
    content = "#{jsonl(2)}{\"type\":\"assistant\",\"text\":\"before\u0000after\"}\n"

    assert_nothing_raised { @session.update!(transcript: content) }

    fresh = Session.find(@session.id)
    assert_equal content.delete("\u0000"), fresh.transcript
    assert_not_includes fresh.transcript, "\u0000"
    assert_equal 3, fresh.transcript_line_count, "stripping a NUL must not change the event count"
    assert_equal fresh.transcript.bytesize, fresh.transcript_byte_size
    assert_equal Digest::SHA256.hexdigest(fresh.transcript), fresh.read_attribute(:transcript_digest)
  end

  test "a transcript that is only a blank line is stored, not discarded" do
    # `String#presence` would swallow this. A poll can genuinely read one blank line
    # off a file the runtime has just started writing, and that is a transcript of
    # one event, not the absence of one.
    @session.update!(transcript: "\n")

    fresh = Session.find(@session.id)
    assert_equal "\n", fresh.transcript, "the bytes must survive the round trip"
    # 0, not 1, and deliberately: `Session.transcript_line_count` has always counted
    # a blank value as zero events, which is what the regression guard compares. The
    # claim here is that the CONTENT is preserved, exactly as the old `json` column
    # preserved it — not that a blank line became an event.
    assert_equal 0, fresh.transcript_line_count
  end

  test "an empty string is the absence of a transcript" do
    @session.update!(transcript: jsonl(3))
    @session.update!(transcript: "")

    assert_nil Session.find(@session.id).transcript
    assert_empty chunks_of(@session)
  end

  test "an append whose tail no longer matches the store falls back to a replace" do
    # A writer working from a base another writer superseded between its read and
    # its lock. The length check cannot see a same-length replacement, so the tail
    # chunk is compared against the same range of the incoming value.
    base = jsonl(5)
    @session.update!(transcript: base)
    stale = Session.find(@session.id)

    # Same length, different bytes — invisible to `SUM(byte_size)`.
    superseded = base.sub("\"text\":\"event\"", "\"text\":\"EVENT\"")
    assert_equal base.bytesize, superseded.bytesize
    SessionTranscriptChunk.where(session_id: @session.id).order(:seq).first
      .update!(content: superseded, byte_size: superseded.bytesize,
               line_count: SessionTranscriptChunk.line_count_for(superseded))

    stale.update!(transcript: base + jsonl(1, start: 5))

    # The append declined, so the chunk set was rebuilt from the incoming value
    # whole rather than splicing its tail onto a document it never saw.
    assert_equal base + jsonl(1, start: 5), stored_bytes(@session)
    assert_equal base + jsonl(1, start: 5), Session.find(@session.id).transcript
  end

  test "an empty write clears the chunk set" do
    @session.update!(transcript: jsonl(3))
    @session.update!(transcript: nil)

    assert_empty chunks_of(@session)
    assert_nil Session.find(@session.id).transcript
    assert_equal 0, Session.find(@session.id).transcript_line_count
    assert_not_predicate Session.find(@session.id), :transcript_present?
  end

  # --- the point of the change: appends are appends -----------------------

  test "extending a transcript writes only the new bytes" do
    base = jsonl(3_000, text: "y" * 200)
    @session.update!(transcript: base)
    before = chunks_of(@session)
    assert_operator before.size, :>, 2

    tail = jsonl(2, start: 3_000)
    @session.update!(transcript: base + tail)

    after = chunks_of(@session)
    # Every chunk that was already closed is untouched — same row, same bytes.
    # This is the whole claim of #110: recording two new events must not rewrite
    # the 600 KB of conversation in front of them.
    closed_before = before[0...-1]
    closed_after = after[0...closed_before.size]
    assert_equal closed_before.map(&:id), closed_after.map(&:id)
    assert_equal closed_before.map(&:content), closed_after.map(&:content)
    assert_equal closed_before.map(&:updated_at), closed_after.map(&:updated_at)

    assert_equal base + tail, Session.find(@session.id).transcript
  end

  test "an append issues no read of the stored transcript" do
    base = jsonl(50)
    @session.update!(transcript: base)
    @session.reload

    selects = chunk_selects_during { @session.update!(transcript: base + jsonl(1, start: 50)) }

    # Two statements, and neither reads the conversation. One is a `SUM(byte_size)`
    # — no `content` at all — that checks the chunk set is as long as the counters
    # claim; the other is the LIMIT 1 lookup of the open tail chunk it is about to
    # top up. Deciding "this extends what is stored" is a digest comparison against
    # the session row, not a re-read of the transcript, which is the whole point.
    assert_equal 2, selects.size, "an append must not materialise the stored transcript: #{selects.inspect}"
    aggregates, rows = selects.partition { |sql| sql.include?("SUM") }
    assert_equal 1, aggregates.size, selects.inspect
    assert_equal 1, rows.size, selects.inspect
    assert_match(/ORDER BY .*seq.*DESC LIMIT/, rows.first)
  end

  test "appending repeatedly leaves the document intact" do
    content = +""
    30.times do |i|
      content << jsonl(1, start: i)
      @session.update!(transcript: content.dup)
    end

    assert_equal content, Session.find(@session.id).transcript
    assert_equal 30, Session.find(@session.id).transcript_line_count
  end

  test "chunk line counts sum to the document's line count" do
    content = jsonl(3_000, text: "z" * 150)
    @session.update!(transcript: content)

    assert_equal Session.transcript_line_count(content), chunks_of(@session).sum(&:line_count)
    assert_equal Session.transcript_line_count(content), Session.find(@session.id).transcript_line_count
  end

  test "every chunk but the last ends at a line break" do
    content = jsonl(3_000, text: "w" * 150)
    @session.update!(transcript: content)

    chunks_of(@session)[0...-1].each do |chunk|
      assert chunk.content.end_with?("\n"),
        "chunk #{chunk.seq} ends mid-line, which would hide a phrase from content search"
    end
  end

  test "writing byte-identical content touches no chunk" do
    content = jsonl(5)
    @session.update!(transcript: content)
    before = chunks_of(@session)

    @session.update!(transcript: content.dup)

    assert_equal before.map(&:updated_at), chunks_of(@session).map(&:updated_at)
  end

  # --- rewrites, and the truncation the guard is about --------------------

  test "a write that is not an extension replaces the chunk set and says so" do
    @session.update!(transcript: jsonl(10))
    replacement = "#{jsonl(2)}{\"type\":\"user\",\"n\":\"different\"}\n"

    logged = nil
    Rails.logger.stub(:warn, ->(message) { logged = message }) do
      @session.update!(transcript: replacement)
    end

    assert_equal replacement, Session.find(@session.id).transcript
    assert_equal replacement, stored_bytes(@session)
    assert_match(/replacing stored transcript with a shorter one/, logged.to_s)
  end

  test "transcript_regression? compares the incoming value against the stored line count" do
    @session.update!(transcript: jsonl(10))
    fresh = Session.find(@session.id)

    assert fresh.transcript_regression?(jsonl(9)), "fewer events is a regression"
    assert_not fresh.transcript_regression?(jsonl(10)), "the same count is not"
    assert_not fresh.transcript_regression?(jsonl(11)), "more events is not"
  end

  test "the regression guard reads the line count without loading the transcript" do
    @session.update!(transcript: jsonl(2_000, text: "q" * 200))
    fresh = Session.find(@session.id)

    selects = chunk_selects_during { assert fresh.transcript_regression?(jsonl(3)) }

    assert_empty selects, "the guard must answer from the session row alone"
  end

  test "a poll that refuses a regression leaves every stored byte in place" do
    # The end-to-end shape of the guard: the shorter value never reaches the
    # setter, so the chunk set is untouched and the transcript is still whole.
    content = jsonl(40)
    @session.update!(transcript: content)
    fresh = Session.find(@session.id)

    shorter = jsonl(5)
    if fresh.transcript_regression?(shorter)
      # what every call site does
    else
      fresh.update!(transcript: shorter)
    end

    assert_equal content, Session.find(@session.id).transcript
    assert_equal 40, Session.find(@session.id).transcript_line_count
  end

  # --- the legacy column fallback -----------------------------------------

  test "a row the backfill has not reached still reads from the legacy column" do
    legacy = jsonl(4)
    store_legacy_transcript(@session, legacy)

    assert_equal legacy, @session.transcript
    assert_equal 4, @session.transcript_line_count
    assert_predicate @session, :transcript_present?
    assert_empty chunks_of(@session)
  end

  test "the legacy Array format still reads back as an Array" do
    events = [ { "type" => "user", "n" => 1 }, { "type" => "assistant", "n" => 2 } ]
    store_legacy_transcript(@session, events)

    assert_equal events, @session.transcript
    assert_equal 2, @session.transcript_line_count
  end

  test "writing to a legacy row moves it into chunks and leaves the column alone" do
    legacy = jsonl(4)
    store_legacy_transcript(@session, legacy)

    @session.update!(transcript: legacy + jsonl(1, start: 4))
    fresh = Session.find(@session.id)

    assert_equal legacy + jsonl(1, start: 4), fresh.transcript
    assert_equal legacy + jsonl(1, start: 4), stored_bytes(@session)
    # Deliberately NOT cleared: a rollback in the window before the backfill runs
    # then still finds the history the old code wrote. `transcript_byte_size` is
    # what makes the chunk set authoritative.
    assert_equal legacy, fresh.read_attribute(:transcript)
  end

  test "an Array assignment is encoded to JSONL, one line per event" do
    events = [ { "a" => 1 }, { "b" => "two\nlines" }, { "c" => 3 } ]
    @session.update!(transcript: events)
    fresh = Session.find(@session.id)

    assert_equal 3, fresh.transcript_line_count
    assert_equal events, fresh.transcript.lines.map { |line| JSON.parse(line) }
    assert_equal 3, fresh.parsed_transcript.length
  end

  # --- plumbing -----------------------------------------------------------

  test "an unsaved assignment reads back before it is persisted" do
    @session.transcript = jsonl(2)

    assert_equal 2, @session.transcript_line_count
    assert_equal jsonl(2), @session.transcript
    assert_empty chunks_of(@session)
  end

  test "reload drops an unsaved assignment" do
    @session.update!(transcript: jsonl(3))
    @session.transcript = jsonl(99)
    @session.reload

    assert_equal 3, @session.transcript_line_count
    assert_equal jsonl(3), @session.transcript
  end

  test "a transcript write still moves the session's updated_at" do
    @session.update!(transcript: jsonl(2))
    before = Session.find(@session.id).updated_at

    travel 2.seconds do
      @session.update!(transcript: jsonl(3))
    end

    assert_operator Session.find(@session.id).updated_at, :>, before,
      "TranscriptArchiveJob's change detection reads updated_at"
  end

  test "a partially selected row does not raise on the transcript accessor" do
    @session.update!(transcript: jsonl(2))
    partial = Session.select(:id, :status).find(@session.id)

    assert_nothing_raised { partial.transcript }
    assert_nil partial.transcript
  end

  test "destroying a session removes its chunks" do
    @session.update!(transcript: jsonl(5))
    assert_operator SessionTranscriptChunk.where(session_id: @session.id).count, :>, 0

    id = @session.id
    @session.destroy!

    assert_equal 0, SessionTranscriptChunk.where(session_id: id).count
  end

  test "content search finds a phrase stored in a chunked transcript" do
    @session.update!(transcript: "#{jsonl(2_000, text: 'filler')}#{JSON.generate({ 'text' => 'needle-in-chunk' })}\n")

    result = SessionContentSearch.new(scope: Session.where(id: @session.id), query: "needle-in-chunk").call

    assert_equal [ @session.id ], result.matched_ids
  end

  test "content search still finds a phrase in a row the backfill has not reached" do
    store_legacy_transcript(@session, "#{jsonl(2)}#{JSON.generate({ 'text' => 'legacy-needle' })}\n")

    result = SessionContentSearch.new(scope: Session.where(id: @session.id), query: "legacy-needle").call

    assert_equal [ @session.id ], result.matched_ids
  end
end
