# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"
require "tmpdir"
require "json"

class TokenUsageBackfillServiceTest < ActiveSupport::TestCase
  def setup
    @root = Dir.mktmpdir("token_usage_backfill_test_")
  end

  def teardown
    FileUtils.rm_rf(@root)
  end

  # --- helpers ---------------------------------------------------------------

  def clone_dir(basename) = "-home-rails--zimmer-clones-#{basename}-1786989710-abcdef12"

  def write_transcript(dir, request_ids)
    FileUtils.mkdir_p(File.join(@root, dir))
    lines = request_ids.map do |request_id|
      {
        "type" => "assistant",
        "uuid" => SecureRandom.uuid,
        "requestId" => request_id,
        "sessionId" => "sess-#{request_id}",
        "isSidechain" => false,
        "timestamp" => "2026-06-01T10:00:00.000Z",
        "message" => {
          "role" => "assistant",
          "model" => "claude-opus-5",
          "usage" => {
            "input_tokens" => 10, "output_tokens" => 20,
            "cache_read_input_tokens" => 100, "cache_creation_input_tokens" => 50,
            "cache_creation" => { "ephemeral_5m_input_tokens" => 0, "ephemeral_1h_input_tokens" => 50 }
          }
        }
      }
    end
    File.write(File.join(@root, dir, "#{SecureRandom.uuid}.jsonl"), lines.map { |l| JSON.generate(l) }.join("\n") + "\n")
  end

  def run_record(**overrides)
    TokenUsageBackfill.create!({ transcript_root: @root, trigger: "automatic" }.merge(overrides))
  end

  def corpus(size)
    size.times { |i| write_transcript(clone_dir("repo#{i}"), [ "req_#{i}_a", "req_#{i}_b" ]) }
  end

  # --- tests -----------------------------------------------------------------

  test "sweeps the whole corpus and marks the run complete" do
    corpus(3)
    run = run_record

    TokenUsageBackfillService.new(run: run).call
    run.reload

    assert run.complete?, "a run given no budget should finish the corpus"
    assert_equal 3, run.directories_done
    assert_equal 3, run.directories_total
    assert_equal 6, SessionTokenUsage.count
    assert_equal 6, run.session_rows
    assert_equal 100, run.progress_pct
  end

  test "a budgeted slice stops early and the next one resumes at the cursor" do
    corpus(3)
    run = run_record

    # Budget 0 ends the slice after its first chunk; chunk size 1 makes each
    # slice exactly one directory, which is the resumption boundary.
    service = -> { TokenUsageBackfillService.new(run: run, budget: 0.seconds, chunk_size: 1).call }

    service.call
    run.reload
    assert_equal 1, run.directories_done
    assert_not run.complete?
    first_cursor = run.cursor
    assert_equal 2, SessionTokenUsage.count

    service.call
    run.reload
    assert_equal 2, run.directories_done
    assert_operator run.cursor, :>, first_cursor, "the cursor must advance so work is not repeated"
    assert_equal 4, SessionTokenUsage.count

    service.call
    run.reload
    assert_equal 3, run.directories_done

    # One more slice finds nothing left and closes the run out.
    service.call
    run.reload
    assert run.complete?
    assert_equal 6, SessionTokenUsage.count
  end

  test "a second run over the same corpus writes no duplicate rows" do
    corpus(3)

    first = run_record
    TokenUsageBackfillService.new(run: first).call
    rows_after_first = SessionTokenUsage.count
    request_ids = SessionTokenUsage.pluck(:request_id).sort

    second = run_record(trigger: "manual")
    TokenUsageBackfillService.new(run: second).call
    second.reload

    assert second.complete?
    assert_equal 3, second.directories_done, "the re-scan still visits every directory"
    assert_equal rows_after_first, SessionTokenUsage.count, "re-ingesting the same corpus must not duplicate rows"
    assert_equal request_ids, SessionTokenUsage.pluck(:request_id).sort
    assert_equal 0, second.session_rows, "a re-scan reports zero NEW rows, which is the honest number"
  end

  test "a run already complete is a no-op" do
    corpus(1)
    run = run_record(finished_at: 1.hour.ago, started_at: 2.hours.ago)

    TokenUsageBackfillService.new(run: run).call

    assert_equal 0, SessionTokenUsage.count
    assert_equal 0, run.reload.directories_done
  end

  test "a missing transcript root is recorded as an error, not as completion" do
    run = run_record(transcript_root: File.join(@root, "does-not-exist"))

    TokenUsageBackfillService.new(run: run).call
    run.reload

    assert_not run.complete?, "a misconfigured root must not be reported as full coverage"
    assert_match "does not exist", run.last_error
    assert_not_nil run.last_ran_at
  end

  test "an empty corpus completes without writing anything" do
    run = run_record

    TokenUsageBackfillService.new(run: run).call

    assert run.reload.complete?
    assert_equal 0, SessionTokenUsage.count
  end

  test "a failing sweep records the error, leaves the cursor put, and raises" do
    corpus(2)
    run = run_record

    TokenUsageIngestionService.any_instance.stubs(:call).raises(Errno::EACCES, "permission denied")

    assert_raises(Errno::EACCES) { TokenUsageBackfillService.new(run: run).call }

    run.reload
    assert_nil run.cursor, "a chunk that failed must not advance the cursor"
    assert_equal 0, run.directories_done
    assert_not run.complete?
    assert_match "Errno::EACCES", run.last_error
  end

  test "a directory created behind the cursor is skipped, and left to the recurring sweep" do
    corpus(2)
    run = run_record

    # One directory swept; the cursor now sits past it.
    TokenUsageBackfillService.new(run: run, budget: 0.seconds, chunk_size: 1).call
    run.reload
    assert_equal 2, SessionTokenUsage.count

    # A clone directory that sorts BEFORE the cursor, created while the run was
    # in flight. The backfill will not go back for it — deliberately: its files
    # are new, so TokenUsageIngestionJob's two-hour lookback already has them.
    write_transcript("-aaa-created-mid-run", [ "req_new" ])

    TokenUsageBackfillService.new(run: run).call
    run.reload

    assert run.complete?
    assert_equal 4, SessionTokenUsage.count, "the corpus as it stood at the cursor, and nothing behind it"
    assert_not_includes SessionTokenUsage.pluck(:request_id), "req_new"
  end
end
