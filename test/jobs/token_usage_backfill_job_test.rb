# frozen_string_literal: true

require "test_helper"
require "json"
require "mocha/minitest"
require "tmpdir"

class TokenUsageBackfillJobTest < ActiveJob::TestCase
  def setup
    @root = Dir.mktmpdir("token_usage_backfill_job_test_")
    # One (empty) transcript directory, so the sweep has a corpus to cover. A
    # root with none at all is a misconfiguration the service refuses to call
    # complete — covered in TokenUsageBackfillServiceTest.
    FileUtils.mkdir_p(File.join(@root, "-home-rails--zimmer-clones-repo-main-1786989710-abcdef12"))
    TokenUsageIngestionService.stubs(:default_root).returns(@root)
    # `sweep_other_runtimes` drives EVERY registered ingestor, and Codex's reads a
    # host-global tree (`~/.codex/sessions`) rather than a corpus a test controls.
    # Left unstubbed, this suite's assertions would depend on whether the machine
    # running it happens to have used Codex.
    CodexTokenUsageIngestionService.stubs(:default_root).returns(File.join(@root, "codex-sessions"))
  end

  def teardown
    FileUtils.rm_rf(@root)
  end

  test "starts and works a run on the first tick when history has never been swept" do
    assert_difference -> { TokenUsageBackfill.count }, 1 do
      TokenUsageBackfillJob.perform_now
    end

    run = TokenUsageBackfill.latest
    assert_equal "automatic", run.trigger
    assert_equal @root, run.transcript_root
    assert run.complete?, "a small corpus is covered in one slice"
  end

  # "Re-scan history" is a request about the LEDGER, not about the Claude corpus.
  # The post-deploy task that shipped Pi's ingestor is terminal, and the recurring
  # job only looks two hours back, so this is the only surface that can recover
  # Pi spend from a gap wider than that window.
  test "a run also sweeps every other runtime's whole history, once, at its head" do
    uuid = SecureRandom.uuid
    Session.create!(
      prompt: "pi", agent_runtime: "pi", status: :archived,
      git_root: "https://github.com/tadasant/zimmer.git", branch: "main", session_id: uuid,
      metadata: { "agent_root_key" => "zimmer" },
      transcript: [
        { "type" => "session", "version" => 3, "id" => uuid, "timestamp" => "2026-01-01T00:00:00.000Z" },
        { "type" => "message", "id" => "feedface", "timestamp" => "2026-01-01T00:00:01.000Z",
          "message" => { "role" => "assistant", "content" => [], "provider" => "openrouter",
                         "model" => "anthropic/claude-haiku-4.5", "stopReason" => "stop",
                         "usage" => { "input" => 1, "output" => 9, "cacheRead" => 0, "cacheWrite" => 0 } } }
      ].map { |e| JSON.generate(e) }.join("\n") + "\n"
    ).update_column(:updated_at, 30.days.ago)

    TokenUsageBackfillJob.perform_now

    # Written despite being far outside TokenUsageIngestionJob's two-hour lookback.
    assert_equal [ "pi:#{uuid}:feedface" ], SessionTokenUsage.pluck(:request_id)
    # And Codex's corpus was asked for too, not skipped — it is simply empty here.
    assert_equal [], CodexTokenUsageIngestionService.rollout_paths
  end

  test "does nothing at all once a sweep has completed — every deploy after the first" do
    TokenUsageBackfillJob.perform_now
    assert TokenUsageBackfill.ever_completed?

    assert_no_difference -> { TokenUsageBackfill.count } do
      assert_nil TokenUsageBackfillJob.perform_now, "a completed backfill leaves nothing to do"
    end
  end

  test "picks up a run somebody asked for even though history is already swept" do
    TokenUsageBackfillJob.perform_now
    requested = TokenUsageBackfill.request!(trigger: "manual")

    TokenUsageBackfillJob.perform_now

    assert requested.reload.complete?
    assert_equal 2, TokenUsageBackfill.count
  end

  test "resumes the unfinished run instead of starting another" do
    stalled = TokenUsageBackfill.create!(transcript_root: @root, started_at: 1.hour.ago)

    assert_no_difference -> { TokenUsageBackfill.count } do
      TokenUsageBackfillJob.perform_now
    end

    assert stalled.reload.complete?
  end

  test "runs on the maintenance queue, not pollers" do
    # Bulk work that holds its thread for minutes must not sit on the queue the
    # latency-sensitive singleton pollers share.
    assert_equal "maintenance", TokenUsageBackfillJob.new.queue_name
  end
end
