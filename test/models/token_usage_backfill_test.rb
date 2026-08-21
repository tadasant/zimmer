# frozen_string_literal: true

require "test_helper"

class TokenUsageBackfillTest < ActiveSupport::TestCase
  def run_record(**overrides)
    TokenUsageBackfill.create!({ transcript_root: "/tmp/projects" }.merge(overrides))
  end

  test "request! returns the run already in flight rather than starting a second" do
    existing = run_record(started_at: 1.minute.ago)

    assert_no_difference -> { TokenUsageBackfill.count } do
      assert_equal existing, TokenUsageBackfill.request!(trigger: "manual")
    end
  end

  test "request! starts a fresh run once the previous one finished" do
    run_record(started_at: 2.hours.ago, finished_at: 1.hour.ago)

    assert_difference -> { TokenUsageBackfill.count }, 1 do
      run = TokenUsageBackfill.request!(trigger: "manual")
      assert_equal "manual", run.trigger
      assert_equal "queued", run.status
    end
  end

  test "status walks queued to running to complete" do
    run = run_record
    assert_equal "queued", run.status

    run.update!(started_at: Time.current)
    assert_equal "running", run.status

    run.update!(finished_at: Time.current)
    assert_equal "complete", run.status
    assert run.complete?
  end

  test "progress is nil before the first slice and 100 once finished" do
    run = run_record
    assert_nil run.progress_pct, "no denominator yet is no information, not zero percent"

    run.update!(directories_total: 200, directories_done: 50)
    assert_equal 25, run.progress_pct

    # A sweep that has covered every directory it knows about is still not
    # complete until the run says so, so it is capped below 100.
    run.update!(directories_done: 200)
    assert_equal 99, run.progress_pct

    run.update!(finished_at: Time.current)
    assert_equal 100, run.progress_pct
  end

  test "coverage reports never_run before any sweep" do
    coverage = TokenUsageBackfill.coverage

    assert_equal "never_run", coverage[:status]
    assert_not coverage[:complete]
    assert_nil coverage[:covers_since]
  end

  test "coverage names the oldest call stored and whether history is in" do
    SessionTokenUsage.create!(
      request_id: "req_old", model: "claude-opus-5", agent_root: "zimmer",
      called_at: Time.zone.parse("2026-01-05T10:00:00Z"), input_tokens: 10, output_tokens: 20
    )
    AdhocTokenUsage.create!(
      request_id: "req_recent", source: "cli_status_probe", model: "claude-opus-5",
      called_at: Time.zone.parse("2026-08-01T10:00:00Z"), input_tokens: 1, output_tokens: 2
    )
    finished = run_record(started_at: 2.hours.ago, finished_at: 1.hour.ago,
                          directories_total: 12, directories_done: 12, files_scanned: 400)

    coverage = TokenUsageBackfill.coverage

    assert coverage[:complete]
    assert_equal "complete", coverage[:status]
    assert_equal finished.finished_at.to_i, coverage[:finished_at].to_i
    assert_equal Time.zone.parse("2026-01-05T10:00:00Z"), coverage[:covers_since]
    assert_equal Time.zone.parse("2026-08-01T10:00:00Z"), coverage[:covers_until]
    assert_equal 400, coverage[:files_scanned]
  end

  test "coverage stays complete while a re-scan is in flight" do
    run_record(started_at: 3.hours.ago, finished_at: 2.hours.ago)
    run_record(trigger: "manual", started_at: 1.minute.ago, directories_total: 10, directories_done: 3)

    coverage = TokenUsageBackfill.coverage

    assert coverage[:complete], "history was swept once; a re-scan does not un-sweep it"
    assert_equal "running", coverage[:status]
    assert_equal 30, coverage[:progress_pct]
  end

  test "rejects an unknown trigger" do
    assert_raises(ActiveRecord::RecordInvalid) { run_record(trigger: "whenever") }
  end
end
