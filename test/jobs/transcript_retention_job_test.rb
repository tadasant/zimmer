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
    CloneDiskGuard.stubs(:available_bytes).returns(nil)
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

    # PiTokenUsageIngestionService's shape: no digest either.
    narrow = Session.select(:id, :transcript, :transcript_byte_size).find(session.id)
    assert_equal content, narrow.transcript
  end

  test "a record loaded before the offload still reads its lines" do
    content = jsonl(30)
    session = archived_session(content: content)
    stale = Session.find(session.id)
    TranscriptRetentionJob.perform_now

    assert_equal content.lines[25..29], stale.each_transcript_line(25, 30).map(&:last)
  end

  test "restore decides from the row, not from a record loaded before the offload" do
    content = jsonl(40)
    session = archived_session(content: content)
    stale = Session.find(session.id) # what unarchive holds when the job commits under it
    TranscriptRetentionJob.perform_now

    assert stale.restore_offloaded_transcript!
    assert_nil Session.find(session.id).transcript_offloaded_at
    assert_equal content, SessionTranscriptChunk.where(session_id: session.id).order(:seq).pluck(:content).join
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
    TranscriptOffloadStore.stubs(:write_stream).raises(TranscriptOffloadStore::Corrupt, "disk said no")

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
    assert_empty Dir.glob(File.join(TranscriptOffloadStore.base, "**", "*.tmp-*")), "the aborted write leaves no temp"
  end

  test "a session skipped for a chunk mismatch is not re-read every tick, until its transcript changes" do
    session = archived_session(content: jsonl(5))
    SessionTranscriptChunk.where(session_id: session.id).order(:seq).last.update_columns(content: "tampered\n")

    assert_equal 1, TranscriptRetentionJob.perform_now[:skipped]
    assert_equal({ offloaded: 0, skipped: 0, failed: 0, bytes: 0 }, TranscriptRetentionJob.perform_now)
    assert_equal 0, TranscriptRetentionJob.candidates.count

    # A rewrite gives it a new digest, and it is a candidate again by itself.
    rewritten = jsonl(6)
    session.reload.update!(transcript: rewritten)
    session.update_columns(status: Session.statuses.fetch("archived"), archived_at: 40.days.ago)

    assert_equal 1, TranscriptRetentionJob.perform_now[:offloaded]
    assert_equal rewritten, Session.find(session.id).transcript
  end

  # A writer that commits after the copy is written but before the job takes the
  # row lock: the copy is now stale, and the locked re-check must notice.
  class RacingRetentionJob < TranscriptRetentionJob
    cattr_accessor :rewrite

    private

    def stream_chunks_to_store(session_id, byte_size, digest)
      super
      Session.find(session_id).update!(transcript: rewrite)
    end
  end

  test "a writer that commits between the copy and the locked re-check keeps its chunks" do
    session = archived_session(content: jsonl(5))
    extended = jsonl(7)
    RacingRetentionJob.rewrite = extended

    result = RacingRetentionJob.new.perform

    assert_equal 1, result[:skipped]
    assert_nil session.reload.transcript_offloaded_at
    assert_equal extended, SessionTranscriptChunk.where(session_id: session.id).order(:seq).pluck(:content).join
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
    File.delete(TranscriptOffloadStore.paths_for(session.id).first)

    reloaded = Session.find(session.id)
    assert_nil reloaded.transcript
    assert reloaded.transcript_present?, "the row still says a transcript existed"
    assert_equal false, reloaded.restore_offloaded_transcript!
  end

  test "does not offload while the store's volume is under the free-space floor" do
    session = archived_session(content: jsonl(5))
    CloneDiskGuard.stubs(:available_bytes).returns(TranscriptRetentionJob::MINIMUM_FREE_BYTES - 1)

    assert_equal 0, TranscriptRetentionJob.perform_now[:offloaded]
    assert_predicate chunk_count(session), :positive?
  end

  test "sweeps temps a killed run left, and spares fresh ones and finished files" do
    session = archived_session(content: jsonl(5))
    TranscriptRetentionJob.perform_now
    finished = TranscriptOffloadStore.paths_for(session.id).first
    old = "#{finished}.tmp-abc123"
    fresh = "#{finished}.tmp-def456"
    [ old, fresh ].each { |path| File.write(path, "x") }
    [ old, finished ].each { |path| File.utime(2.hours.ago.to_time, 2.hours.ago.to_time, path) }

    TranscriptRetentionJob.perform_now

    assert_not File.exist?(old)
    assert File.exist?(fresh)
    assert File.exist?(finished)
  end

  test "a broken store ends the tick instead of failing every candidate" do
    5.times { archived_session(content: jsonl(2)) }
    TranscriptOffloadStore.stubs(:write_stream).raises(Errno::EROFS)

    assert_equal TranscriptRetentionJob::MAX_CONSECUTIVE_FAILURES, TranscriptRetentionJob.perform_now[:failed]
  end

  test "a session set aside for a mismatch is counted, and repairing its chunks brings it back" do
    content = jsonl(5)
    session = archived_session(content: content)
    SessionTranscriptChunk.where(session_id: session.id).order(:seq).last.update_columns(content: "bad\n", byte_size: 4)
    TranscriptRetentionJob.perform_now
    assert_equal 1, TranscriptRetentionJob.skipped_for_mismatch.count

    Session.find(session.id).update!(transcript: content)

    assert_equal 0, TranscriptRetentionJob.skipped_for_mismatch.count
    assert_equal 1, TranscriptRetentionJob.perform_now[:offloaded]
  end

  test "destroying a session removes its offloaded transcript" do
    session = archived_session(content: jsonl(5))
    TranscriptRetentionJob.perform_now
    assert TranscriptOffloadStore.exist?(session.id)

    Session.find(session.id).destroy!

    assert_not TranscriptOffloadStore.exist?(session.id)
  end

  test "offloads nothing from a process in another environment than the database's" do
    session = archived_session(content: jsonl(5))
    metadata = ActiveRecord::Base.connection_pool.internal_metadata
    TranscriptOffloadStore.prepare!
    metadata[TranscriptOffloadStore::STORE_ENVIRONMENT_KEY] = "production"

    assert_equal 0, TranscriptRetentionJob.perform_now[:offloaded]
    assert_predicate chunk_count(session), :positive?
    assert_nil session.reload.transcript_offloaded_at
    assert_empty Dir.glob(File.join(@root, "**", "*.gz*"))
  end

  test "destroying another database's session with the same id keeps this one's transcript" do
    content = jsonl(5)
    session = archived_session(content: content)
    TranscriptRetentionJob.perform_now
    metadata = ActiveRecord::Base.connection_pool.internal_metadata
    mine = metadata[TranscriptOffloadStore::STORE_ID_KEY]

    metadata[TranscriptOffloadStore::STORE_ID_KEY] = SecureRandom.uuid
    Session.find(session.id).send(:reclaim_session_directories)
    metadata[TranscriptOffloadStore::STORE_ID_KEY] = mine

    assert_equal content, Session.find(session.id).transcript
  end

  test "a database with nothing to offload leaves nothing on the volume" do
    TranscriptRetentionJob.perform_now

    assert_empty Dir.children(@root)
  end
end
