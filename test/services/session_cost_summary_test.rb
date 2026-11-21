# frozen_string_literal: true

require "test_helper"
require "json"

# The per-session spend the detail page and `get_session` both state.
class SessionCostSummaryTest < ActiveSupport::TestCase
  # One assistant entry copied from a live Pi session on
  # `openrouter/~x-ai/grok-latest` (session #29790), down to the `cost` Pi
  # recorded beside the volumes. That recorded cost is the figure this
  # deployment's ledger has to reproduce.
  GROK_ENTRY = {
    "type" => "message", "id" => "4336f418", "parentId" => "d8150f1e",
    "timestamp" => "2026-11-21T14:23:48.633Z",
    "message" => {
      "role" => "assistant", "content" => [ { "type" => "text", "text" => "done" } ],
      "api" => "openai-completions", "provider" => "openrouter", "model" => "~x-ai/grok-latest",
      "usage" => {
        "input" => 647, "output" => 786, "cacheRead" => 57_216, "cacheWrite" => 0,
        "reasoning" => 399, "totalTokens" => 58_649,
        "cost" => { "input" => 0.001294, "output" => 0.004716, "cacheRead" => 0.028608,
                    "cacheWrite" => 0, "total" => 0.034618 }
      },
      "stopReason" => "stop", "responseModel" => "x-ai/grok-4.3"
    }
  }.freeze

  def pi_session(entries)
    uuid = SecureRandom.uuid
    header = { "type" => "session", "version" => 3, "id" => uuid, "timestamp" => "2026-11-21T13:56:37.791Z" }
    Session.create!(
      title: "pi session", prompt: "x", agent_runtime: "pi",
      git_root: "https://github.com/tadasant/zimmer.git", branch: "main",
      session_id: uuid,
      transcript: ([ header ] + entries).map { |e| JSON.generate(e) }.join("\n") + "\n",
      metadata: { "agent_root_key" => "inference-gateway" }
    )
  end

  test "a Pi session on grok-latest prices to the cost Pi itself recorded" do
    session = pi_session([ GROK_ENTRY ])
    PiTokenUsageIngestionService.new(session_ids: [ session.id ]).call

    summary = SessionCostSummary.for(session)

    assert summary.any?
    assert_in_delta 0.034618, summary.cost, 1e-9
    assert_equal 1, summary.api_calls
    assert_equal 647, summary.input_tokens
    assert_equal 786, summary.output_tokens
    assert_equal 57_216, summary.cache_read_tokens
    assert_equal 0, summary.cache_write_tokens
    assert_equal 58_649, summary.total_tokens
    assert_empty summary.unpriced_models
    refute summary.unpriced?
    assert summary.metered?
    assert_match(/money owed/, summary.basis)
    assert_equal "647 input, 786 output, 57,216 cache read, 0 cache write, across 1 API call.",
                 summary.breakdown_sentence
  end

  test "usage on a model with no rate reads as unpriced, never as free" do
    pinned = GROK_ENTRY.deep_dup
    pinned["message"]["model"] = "x-ai/grok-4.3"
    session = pi_session([ pinned ])
    PiTokenUsageIngestionService.new(session_ids: [ session.id ]).call

    summary = SessionCostSummary.for(session)

    assert summary.any?
    assert_equal 0.0, summary.cost
    assert summary.unpriced?
    assert_equal [ "openrouter/x-ai/grok-4.3" ], summary.unpriced_models
  end

  test "a Claude Code session's figure is described as list price, not a bill" do
    session = sessions(:running)
    SessionTokenUsage.create!(request_id: "req_#{SecureRandom.hex(6)}", model: "claude-opus-5",
                              session_id: session.id, agent_root: "zimmer", called_at: 1.hour.ago,
                              input_tokens: 1_000, output_tokens: 2_000)

    summary = SessionCostSummary.for(session.reload)

    refute summary.metered?
    assert_match(/list price/, summary.basis)
    assert_in_delta (1_000 * 5.0 + 2_000 * 25.0) / 1_000_000.0, summary.cost, 1e-9
  end

  test "a session with nothing stored is empty" do
    summary = SessionCostSummary.for(sessions(:running))

    refute summary.any?
    refute summary.unpriced?
    assert_equal 0, summary.total_tokens
  end

  test "compact token counts" do
    assert_equal "940", SessionCostSummary.compact_tokens(940)
    assert_equal "58.6K", SessionCostSummary.compact_tokens(58_649)
    assert_equal "2K", SessionCostSummary.compact_tokens(2_000)
    assert_equal "2.37M", SessionCostSummary.compact_tokens(2_373_445)
    assert_equal "3M", SessionCostSummary.compact_tokens(3_000_000)
    assert_equal "1M", SessionCostSummary.compact_tokens(999_960)
    assert_equal "999.9K", SessionCostSummary.compact_tokens(999_900)
  end
end
