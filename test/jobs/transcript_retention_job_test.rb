# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# TranscriptRetentionJob moves the transcripts of long-archived sessions out of
# `session_transcript_chunks`. The assertions that matter most are the negative
# ones: a chunk row is deleted only once a verified copy exists, and nothing a
# reader could ask of the transcript changes when it moves.
class TranscriptRetentionJobTest < ActiveJob::TestCase
  setup do
    @root = Dir.mktmpdir("transcript_offload_test")
    @previous_dir = ENV[TranscriptOffloadStore::DIR_ENV]
    ENV[TranscriptOffloadStore::DIR_ENV] = @root
  end

  teardown do
    ENV[TranscriptOffloadStore::DIR_ENV] = @previous_dir
    FileUtils.rm_rf(@root)
  end

  def jsonl(count, start: 0)
    (start...(start + count)).map { |i| JSON.generate({ "type" => "assistant", "n" => i, "text" => "x" * 300 }) }.join("\n") + "\n"
  end

  def archived_session(archived_at: 40.days.ago, content: jsonl(2_000))
    session = create_session(prompt: "retention")
    session.update!(transcript: content)
    session.update_columns(status: Session.statuses.fetch("archived"), archived_at: archived_at)
    session.reload
  end

  def chunk_count(session) = SessionTranscriptChunk.where(session_id: session.id).count

  test "offloads a long-archived transcript, deletes its chunks, and it still reads back byte for byte" do
    content = jsonl(2_000)
    session = archived_session(content: content)
    assert_operator chunk_count(session), :>, 1, "the fixture should span several chunks"
    updated_at = session.updated_at

    result = TranscriptRetentionJob.perform_now

    assert_equal 1, result[:offloaded]
    assert_equal content.bytesize, result[:bytes]
    assert_equal 0, chunk_count(session)
    assert TranscriptOffloadStore.exist?(session.id)

    reloaded = Session.find(session.id)
    assert reloaded.transcript_offloaded?
    assert_equal content, reloaded.transcript
    assert_equal 2_000, reloaded.transcript_line_count
    assert_equal content.bytesize, reloaded.transcript_byte_size
    assert reloaded.transcript_matches?(content)
    assert_equal updated_at.to_i, reloaded.updated_at.to_i,
      "updated_at must not move, or TranscriptArchiveJob re-archives every offloaded session"
  end

  test "bounded line reads and the head read still answer for an offloaded transcript" do
    content = jsonl(50)
    session = archived_session(content: content)
    TranscriptRetentionJob.perform_now

    reloaded = Session.find(session.id)
    lines = reloaded.each_transcript_line(45, 50).to_a
    assert_equal (45...50).to_a, lines.map(&:first)
    assert_equal content.lines[45..49], lines.map(&:last)
    assert_equal [], reloaded.transcript_head_lines(4096), "an empty head tells the caller to read the long way"
  end

  test "a partial select that leaves out the marker still reads the offloaded transcript" do
    content = jsonl(10)
    session = archived_session(content: content)
    TranscriptRetentionJob.perform_now

    partial = Session.select(:id, :transcript, :transcript_byte_size, :transcript_digest).find(session.id)
    assert_equal content, partial.transcript
  end

  test "leaves recent archives, live sessions and already-offloaded sessions alone" do
    recent = archived_session(archived_at: 2.days.ago)
    live = create_session(prompt: "live")
    live.update!(transcript: jsonl(5))
    live.update_columns(archived_at: 90.days.ago)

    result = TranscriptRetentionJob.perform_now

    assert_equal 0, result[:offloaded]
    assert_predicate chunk_count(recent), :positive?
    assert_predicate chunk_count(live), :positive?
    assert_nil recent.reload.transcript_offloaded_at
  end

  test "a second run is a no-op" do
    archived_session
    assert_equal 1, TranscriptRetentionJob.perform_now[:offloaded]
    assert_equal({ offloaded: 0, skipped: 0, failed: 0, bytes: 0 }, TranscriptRetentionJob.perform_now)
  end

  test "honours TRANSCRIPT_RETENTION_DAYS" do
    session = archived_session(archived_at: 10.days.ago)
    ENV[TranscriptRetentionJob::RETENTION_DAYS_ENV] = "7"

    assert_equal 1, TranscriptRetentionJob.perform_now[:offloaded]
    assert session.reload.transcript_offloaded?
  ensure
    ENV.delete(TranscriptRetentionJob::RETENTION_DAYS_ENV)
  end

  test "never deletes chunks when the copy could not be written and verified" do
    session = archived_session
    TranscriptOffloadStore.stubs(:write).raises(TranscriptOffloadStore::Corrupt, "disk said no")

    result = TranscriptRetentionJob.perform_now

    assert_equal 1, result[:failed]
    assert_predicate chunk_count(session), :positive?
    assert_nil session.reload.transcript_offloaded_at
  end

  test "skips a session whose chunks disagree with its row" do
    session = archived_session
    SessionTranscriptChunk.where(session_id: session.id).order(:seq).last.update_columns(content: "tampered\n")

    result = TranscriptRetentionJob.perform_now

    assert_equal 1, result[:skipped]
    assert_predicate chunk_count(session), :positive?
    assert_not TranscriptOffloadStore.exist?(session.id)
  end

  test "skips a session that is being unarchived right now" do
    session = archived_session
    session.merge_metadata!(Session::UNARCHIVE_IN_FLIGHT_KEY => Time.current.utc.iso8601)

    result = TranscriptRetentionJob.perform_now

    assert_equal 1, result[:skipped]
    assert_predicate chunk_count(session), :positive?
  end

  test "stops at the slice budget and leaves the rest for the next tick" do
    archived_session
    archived_session

    assert_equal 0, TranscriptRetentionJob.perform_now(budget: 0)[:offloaded]
    assert_equal 2, TranscriptRetentionJob.perform_now[:offloaded]
  end

  test "restore_offloaded_transcript! puts the chunks back and clears the marker" do
    content = jsonl(1_500)
    session = archived_session(content: content)
    TranscriptRetentionJob.perform_now

    reloaded = Session.find(session.id)
    assert reloaded.restore_offloaded_transcript!

    assert_not reloaded.transcript_offloaded?
    assert_operator chunk_count(reloaded), :>, 1
    assert_equal content, SessionTranscriptChunk.where(session_id: session.id).order(:seq).pluck(:content).join
    assert_equal content, Session.find(session.id).transcript
  end

  test "a write to an offloaded session makes the chunk table the authority again" do
    content = jsonl(20)
    session = archived_session(content: content)
    stale = Session.find(session.id) # loaded before the offload: its marker is nil in memory
    TranscriptRetentionJob.perform_now

    extended = content + jsonl(3, start: 20)
    stale.update!(transcript: extended)

    reloaded = Session.find(session.id)
    assert_nil reloaded.transcript_offloaded_at
    assert_equal extended, reloaded.transcript
    assert_equal extended, SessionTranscriptChunk.where(session_id: session.id).order(:seq).pluck(:content).join
  end

  test "a missing offload file reads as nil rather than raising" do
    session = archived_session(content: jsonl(5))
    TranscriptRetentionJob.perform_now
    File.delete(TranscriptOffloadStore.path_for(session.id))

    reloaded = Session.find(session.id)
    assert_nil reloaded.transcript
    assert reloaded.transcript_present?, "the row still says a transcript existed"
    assert_equal false, reloaded.restore_offloaded_transcript!
  end
end
