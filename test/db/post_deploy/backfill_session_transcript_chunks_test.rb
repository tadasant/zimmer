# frozen_string_literal: true

require "test_helper"

# #110's data half: every transcript written before the chunk store existed is
# still in `sessions.transcript`, and this task is what moves it — verified byte
# for byte, one row at a time, without ever leaving a session unreadable.
class BackfillSessionTranscriptChunksTest < ActiveSupport::TestCase
  setup do
    @entry = PostDeployTask::Registry.find("20260906170500")
    assert @entry, "the task file must ship in db/post_deploy"
    @task_class = @entry.task_class

    # The fixtures carry legacy transcripts of their own; they are part of the
    # corpus this walks, and several assertions below are about "nothing left",
    # so they get migrated along with whatever the test creates.
    @fixture_rows = Session.where.not(transcript: nil).count
  end

  def run_task(deadline: nil)
    run = PostDeployTaskRun.ledger_for(@entry)
    run.claim!(owner: "test")
    outcome = @task_class.new(run: run, deadline: deadline, logger: Rails.logger).up
    [ run.reload, outcome ]
  end

  def legacy_session(value)
    session = create_session(prompt: "backfill #{SecureRandom.hex(4)}", title: "backfill")
    store_legacy_transcript(session, value)
  end

  def chunk_text(session)
    SessionTranscriptChunk.where(session_id: session.id).order(:seq).pluck(:content).join
  end

  def jsonl(count, text: "event")
    (0...count).map { |i| JSON.generate({ "type" => "assistant", "n" => i, "text" => text }) }.join("\n") + "\n"
  end

  test "a legacy transcript reads back byte for byte from the chunks, and the column is freed" do
    content = jsonl(2_000, text: "p" * 200)
    assert_operator content.bytesize, :>, SessionTranscriptChunk::TARGET_BYTES,
      "the fixture must need more than one chunk"
    session = legacy_session(content)

    run, = run_task

    fresh = Session.find(session.id)
    assert_equal content, chunk_text(session), "the chunk set must reproduce the source exactly"
    assert_equal content, fresh.transcript
    assert_nil fresh.read_attribute(:transcript), "the legacy column is freed once the copy is verified"
    assert_equal content.bytesize, fresh.transcript_byte_size
    assert_equal 2_000, fresh.transcript_line_count
    assert_equal Digest::SHA256.hexdigest(content), fresh.read_attribute(:transcript_digest)
    assert_operator run.stats["migrated"], :>=, 1
  end

  test "the legacy Array format is encoded to JSONL, event for event" do
    events = [ { "type" => "user", "text" => "a\nb" }, { "type" => "assistant", "text" => "c" } ]
    session = legacy_session(events)

    run_task

    fresh = Session.find(session.id)
    assert_equal events, fresh.transcript.lines.map { |line| JSON.parse(line) }
    assert_equal 2, fresh.transcript_line_count
    assert_nil fresh.read_attribute(:transcript)
  end

  test "a row already written through the chunk store keeps its chunks and loses the stale column" do
    session = create_session(prompt: "already chunked", title: "already chunked")
    session.update!(transcript: jsonl(5))
    # What a rolling deploy leaves behind: an old container wrote the column after
    # a new one had already written the chunks.
    Session.where(id: session.id).update_all(transcript: "stale from an old container\n")

    run, = run_task

    fresh = Session.find(session.id)
    assert_equal jsonl(5), fresh.transcript, "the chunk set stays authoritative"
    assert_nil fresh.read_attribute(:transcript)
    assert_operator run.stats["already_chunked"], :>=, 1
  end

  test "running it twice is a no-op" do
    session = legacy_session(jsonl(10))
    run_task
    first = chunk_text(session)

    migrated_after_first = PostDeployTaskRun.ledger_for(@entry).stats["migrated"]
    run, outcome = run_task

    assert_nil outcome
    assert_equal first, chunk_text(session)
    # The ledger's counters are cumulative across slices, so "nothing happened" is
    # the total not moving rather than a zero.
    assert_equal migrated_after_first, run.stats["migrated"], "a second run finds nothing left to move"
    assert_equal 0, Session.where.not(transcript: nil).count
  end

  test "a copy that does not verify keeps the legacy column and reports itself" do
    session = legacy_session(jsonl(6))

    # Corrupt the copy between writing it and checking it: exactly the class of
    # failure the verification exists for, since a wrong copy plus a cleared column
    # is unrecoverable data loss.
    SessionTranscriptChunk.stub(:rows_for, ->(**kwargs) { [ { session_id: kwargs[:session_id], seq: 0, content: "truncated\n", byte_size: 10, line_count: 1, created_at: Time.current, updated_at: Time.current } ] }) do
      run, = run_task
      assert_operator run.stats["verification_failures"], :>=, 1
    end

    fresh = Session.find(session.id)
    assert_equal jsonl(6), fresh.read_attribute(:transcript), "the source must survive a failed copy"
    assert_equal jsonl(6), fresh.transcript, "and the session must still read it"
    assert_equal 0, SessionTranscriptChunk.where(session_id: session.id).count,
      "the unverified chunks are removed so the fallback stays in charge"
  end

  test "a row that did not migrate is named on the ledger, not just counted" do
    # `sweep` advances its cursor past a batch whether or not every row in it
    # worked, so this task can finish `succeeded` with transcripts still in the
    # column. Phase 2 gates on this list being empty rather than on the run being
    # green, which only works if the list actually names the rows.
    session = legacy_session(jsonl(4))

    SessionTranscriptChunk.stub(:rows_for, ->(**kwargs) { [ { session_id: kwargs[:session_id], seq: 0, content: "wrong\n", byte_size: 6, line_count: 1, created_at: Time.current, updated_at: Time.current } ] }) do
      run, = run_task

      assert_includes run.stats["unmigrated_session_ids"], session.id
      assert_equal run.stats["verification_failures"], run.stats["unmigrated_session_ids"].size,
        "every failure is small enough here to be named"
    end

    assert_equal jsonl(4), Session.find(session.id).transcript
    assert_not_nil Session.find(session.id).read_attribute(:transcript)
  end

  test "an empty legacy value is retired without writing a chunk" do
    session = legacy_session([])

    run_task

    fresh = Session.find(session.id)
    assert_nil fresh.read_attribute(:transcript)
    assert_nil fresh.transcript
    assert_equal 0, SessionTranscriptChunk.where(session_id: session.id).count
  end

  test "it resumes from its cursor when the slice runs out of budget" do
    5.times { legacy_session(jsonl(3)) }
    remaining = Session.where.not(transcript: nil).count
    assert_operator remaining, :>=, 5

    run = PostDeployTaskRun.ledger_for(@entry)
    run.claim!(owner: "test")
    outcome = @task_class.new(run: run, deadline: 1.second.ago, logger: Rails.logger).up

    assert_equal PostDeployTask::CONTINUE, outcome, "an exhausted budget asks to be resumed"
    assert run.reload.cursor["sweep_last_id"].present?, "and records where it stopped"

    # Resumed slices finish the corpus; nothing is skipped and nothing is redone.
    10.times do
      break if Session.where.not(transcript: nil).count.zero?

      resumed = PostDeployTaskRun.ledger_for(@entry)
      resumed.update!(status: :running) unless resumed.running?
      @task_class.new(run: resumed, deadline: 30.seconds.from_now, logger: Rails.logger).up
    end

    assert_equal 0, Session.where.not(transcript: nil).count
  end

  test "the whole corpus reads identically before and after" do
    # JSONL only: the legacy Array format is re-encoded rather than preserved
    # verbatim (the test above pins that, event for event). Everything that is
    # already text must come back the same bytes.
    sessions = [
      legacy_session(jsonl(3)),
      legacy_session(jsonl(1_500, text: "r" * 200)),
      legacy_session(JSON.generate({ "type" => "user", "text" => "héllo ünïcode 日本語" }) + "\n")
    ]
    before = sessions.to_h { |s| [ s.id, Session.find(s.id).transcript ] }

    run_task

    sessions.each do |session|
      assert_equal before[session.id], Session.find(session.id).transcript,
        "session #{session.id} must read identically after the move"
    end
    assert_equal 0, Session.where.not(transcript: nil).count
  end
end
