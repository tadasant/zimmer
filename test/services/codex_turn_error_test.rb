# frozen_string_literal: true

require "test_helper"

# Every rollout here was written by the real codex-cli 0.146.0 against a fake
# backend returning the named failure (see CodexRolloutFixtures). The expected
# kinds are the recovery path each one must take — and the negative cases are
# the ones that must NOT take any, because a classifier that answers wrongly
# spends a retry budget re-running a turn that cannot succeed.
class CodexTurnErrorTest < ActiveSupport::TestCase
  EXPECTED_KINDS = {
    server_500: :retryable,
    overloaded_503: :retryable,
    rate_429: :retryable,
    insufficient_quota_http: :retryable,
    server_overloaded_stream: :retryable,
    usage_limit_with_windows: :quota,
    usage_limit_without_windows: :quota,
    usage_not_included: :quota,
    quota_stream: :quota,
    context_window_stream: :context_length,
    context_length_http_400: :context_length,
    refresh_token_reused: :auth,
    refresh_token_expired: :auth,
    unauthorized_after_refresh: :auth,
    bad_request_400: :unclassified
  }.freeze

  EXPECTED_KINDS.each do |fixture, kind|
    test "classifies the real #{fixture} rollout as #{kind}" do
      error = CodexTurnError.terminal(codex_rollout(fixture))

      assert error, "expected #{fixture} to end on a recorded turn error"
      assert_equal kind, error.kind
      assert_equal kind != :unclassified, error.recognized?
    end
  end

  # --- negatives: nothing to recover ------------------------------------------

  test "a turn that completed has no terminal error" do
    assert_nil CodexTurnError.terminal(codex_rollout(:completed))
  end

  test "a context-window failure followed by the resume that compacted and completed has none" do
    rollout = codex_rollout(:context_window_then_compacted)
    assert_includes rollout, %("type":"compacted"), "the fixture should carry Codex's own compaction record"

    assert_nil CodexTurnError.terminal(rollout)
  end

  test "an earlier failed turn is not the terminal error once a later turn has started" do
    # A resumed turn that has not ended (or died without Codex writing how) must
    # not be read as dying on the previous turn's error.
    started = { "timestamp" => "2026-09-11T14:00:00Z", "type" => "event_msg",
                "payload" => { "type" => "task_started", "turn_id" => "later-turn" } }.to_json

    assert_nil CodexTurnError.terminal("#{codex_rollout(:server_500)}#{started}\n")
  end

  test "an aborted latest turn has no terminal error" do
    aborted = { "type" => "event_msg", "payload" => { "type" => "turn_aborted", "turn_id" => "t" } }.to_json

    assert_nil CodexTurnError.terminal("#{codex_rollout(:server_500)}#{aborted}\n")
  end

  test "blank, malformed and half-flushed rollouts have no terminal error" do
    assert_nil CodexTurnError.terminal(nil)
    assert_nil CodexTurnError.terminal("")
    assert_nil CodexTurnError.terminal("not json\n{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_comp")
  end

  test "a 400 that is not about the context window is unclassified, not a compaction" do
    error = CodexTurnError.terminal(codex_rollout(:bad_request_400))

    assert_equal "other", error.code
    assert_equal :unclassified, error.kind
  end

  test "an 'other' error that merely mentions the context window in prose is not a compaction" do
    error = CodexTurnError.new(message: "tool output: context_length_exceeded appears in this file",
      info: "other", turn_id: "t", line: 1)

    assert_equal :unclassified, error.kind
  end

  test "an unknown structured code is unclassified" do
    assert_equal :unclassified, CodexTurnError.new(message: "x", info: "sandbox_error", turn_id: "t", line: 1).kind
  end

  # --- detail ------------------------------------------------------------------

  test "reads the HTTP status from Codex's structured detail" do
    error = CodexTurnError.terminal(codex_rollout(:rate_429))

    assert_equal "response_too_many_failed_attempts", error.code
    assert_equal 429, error.http_status
    assert error.rate_limited?
  end

  test "reads the HTTP status from Codex's prose when the code is 'other'" do
    assert_equal 503, CodexTurnError.terminal(codex_rollout(:overloaded_503)).http_status
    assert_equal 401, CodexTurnError.terminal(codex_rollout(:unauthorized_after_refresh)).http_status
  end

  test "a 500 Codex reworded is recognized by its code, not its prose" do
    error = CodexTurnError.terminal(codex_rollout(:server_500))

    assert_equal "We're currently experiencing high demand, which may cause temporary errors.", error.message
    assert_nil error.http_status
    assert_not error.rate_limited?
    assert_equal :retryable, error.kind
  end

  test "identifies the failed turn by Codex's turn id, falling back to its line" do
    error = CodexTurnError.terminal(codex_rollout(:server_500))

    assert_match(/\A01a090a3-/, error.id)
    assert_equal "line:7", CodexTurnError.new(message: "", info: "other", turn_id: nil, line: 7).id
  end

  # --- quota reading -----------------------------------------------------------

  test "a usage-limit refusal carries the windows Codex recorded with it" do
    error = CodexTurnError.terminal(codex_rollout(:usage_limit_with_windows))
    reading = error.quota_reading

    assert_in_delta 1.0, reading.utilization_5h
    assert_equal Time.zone.at(1789136947), reading.reset_5h
    assert_in_delta 0.425, reading.utilization_7d
    assert_equal Time.zone.at(1789533347), reading.reset_7d
    # The weekly window has room, so the account is back when the capped
    # five-hour window resets — not at the weekly rollover.
    assert_equal Time.zone.at(1789136947), reading.restores_at
  end

  test "a refusal that came with no windows yields no reading" do
    assert_nil CodexTurnError.terminal(codex_rollout(:usage_limit_without_windows)).quota_reading
  end

  test "a reading with no window at its cap does not explain the refusal, so it is not kept" do
    limits = { "primary" => { "used_percent" => 97.0, "window_minutes" => 300, "resets_at" => 1_789_136_947 } }

    assert_nil CodexTurnError.new(message: "", info: "usage_limit_exceeded", turn_id: "t", line: 1,
      rate_limits: limits).quota_reading
  end

  test "a capped window with no reset time is not evidence of when the account returns" do
    limits = {
      "primary" => { "used_percent" => 100.0, "window_minutes" => 300, "resets_at" => nil },
      "secondary" => { "used_percent" => 10.0, "window_minutes" => 10080, "resets_at" => 1_789_533_347 }
    }

    assert_nil CodexTurnError.new(message: "", info: "usage_limit_exceeded", turn_id: "t", line: 1,
      rate_limits: limits).quota_reading
  end

  test "the reading answers the fields QuotaSnapshotService saves" do
    reading = CodexTurnError.terminal(codex_rollout(:usage_limit_with_windows)).quota_reading

    %i[subscription_type rate_limit_tier utilization_5h utilization_7d status_5h status_7d
       reset_5h reset_7d overage_status overage_disabled_reason].each do |field|
      assert_respond_to reading, field
    end
  end
end
