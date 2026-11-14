# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class LiveConversations::ClaudeDelegateTest < ActiveSupport::TestCase
  setup do
    @conversation = create_live_conversation(mode: "voice", voice_engine: "gpt_live_claude")
    @conversation.turns.create!(role: "user", source: "spoken", content: "Hi there.")
  end

  test "runs Zimmer's tools in a Claude loop, answers in chunks, and prices every call" do
    claude = LiveConversationHelpers::FakeClaude.new(responses: [
      LiveConversationHelpers::FakeClaude.tool("get_live_settings", {}, input: 4_000, output: 50, cache_write: 3_000),
      LiveConversationHelpers::FakeClaude.text("You're on the Sonnet model. Speed is normal.", input: 200, output: 30, cache_read: 3_000)
    ])

    result = LiveConversations::ClaudeDelegate.call(@conversation, delegation_id: "item_del_1",
                                                    pending_user_text: "What model are you on?", client: claude)

    assert_equal "You're on the Sonnet model. Speed is normal.", result.text
    assert_equal [ "You're on the Sonnet model. Speed is normal." ], result.chunks
    assert_not result.end_call
    assert_equal 2, result.rounds

    first = claude.requests.first
    assert_equal "claude-sonnet-5-5", first["model"]
    assert_equal({ "type" => "ephemeral" }, first["system_"].sole["cache_control"])
    assert_includes first["system_"].sole["text"], "You are answering a delegation"
    assert_includes first["tools"].map { |tool| tool["name"] }, "hang_up"
    assert first["tools"].all? { |tool| tool["input_schema"].is_a?(Hash) }
    assert_includes first["messages"].sole["content"], "Them: Hi there."
    assert_includes first["messages"].sole["content"], "What model are you on?"
    # The tool's result went back as a tool_result for the same id.
    second = claude.requests.second
    tool_result = second["messages"].last["content"].sole
    assert_equal "toolu_1", tool_result["tool_use_id"]
    assert_includes tool_result["content"], "voice_engine"
    assert_equal "get_live_settings", @conversation.turns.last.tool_name

    calls = LiveUsageEvent.where(operation: "delegation").order(:id)
    assert_equal 2, calls.count
    assert_equal [ 4_000, 200 ], calls.map(&:input_tokens)
    assert_equal [ 0, 3_000 ], calls.map(&:cache_read_tokens)
    assert calls.all? { |row| row.engine == "gpt_live_claude" && row.live_conversation_id == @conversation.id && row.latency_ms }
    # 4000*2 + 50*10 + 3000*2.5 per million, then 200*2 + 30*10 + 3000*0.1 per million
    assert_in_delta 0.0160 + 0.0010, calls.sum(&:cost_usd).to_f, 0.000001
    assert_in_delta calls.sum(&:cost_usd).to_f, result.cost_usd, 0.000001
    tool_row = LiveUsageEvent.find_by!(operation: "tool_call")
    assert_equal "get_live_settings", tool_row.model
    assert_equal 0, tool_row.cost_usd
  end

  test "a delegation is priced on the model asked for, even when the API answers with a dated snapshot" do
    claude = LiveConversationHelpers::FakeClaude.new(responses: [
      LiveConversationHelpers::FakeClaude.text("Done.", model: "claude-sonnet-5-5-20261101", input: 1_000_000)
    ])

    LiveConversations::ClaudeDelegate.call(@conversation, delegation_id: "d", client: claude)

    row = LiveUsageEvent.sole
    assert_equal "claude-sonnet-5-5", row.model
    assert row.priced
    assert_in_delta 2.0 + 0.001, row.cost_usd.to_f, 0.000001
    assert_equal "claude-sonnet-5-5-20261101", row.details["response_model"]
  end

  test "the last round may not call tools, so nothing runs whose result nobody reads" do
    responses = Array.new(LiveConversations::ClaudeDelegate::MAX_ROUNDS - 1) { |i| LiveConversationHelpers::FakeClaude.tool("get_live_settings", id: "toolu_#{i}") }
    claude = LiveConversationHelpers::FakeClaude.new(responses: responses + [ LiveConversationHelpers::FakeClaude.text("Here's what I found.") ])

    result = LiveConversations::ClaudeDelegate.call(@conversation, delegation_id: "d", client: claude)

    assert_equal "Here's what I found.", result.text
    assert_equal [ nil ] * (LiveConversations::ClaudeDelegate::MAX_ROUNDS - 1) + [ { "type" => "none" } ], claude.requests.map { |r| r["tool_choice"] }
  end

  test "no Claude Code account is not spoken as a backend failure: it is a 503 for the dock" do
    without_claude_code_account

    assert_raises(LiveConversations::ClaudeClient::NotConfiguredError) do
      LiveConversations::ClaudeDelegate.call(@conversation, delegation_id: "d")
    end
  end

  test "a hang-up ends the call once the goodbye is said" do
    claude = LiveConversationHelpers::FakeClaude.new(responses: [ LiveConversationHelpers::FakeClaude.tool("hang_up") ])

    result = LiveConversations::ClaudeDelegate.call(@conversation, delegation_id: "d", client: claude)

    assert result.end_call
    assert result.hung_up
    assert_equal 1, claude.requests.size
  end

  test "an engine at its spend cap does not call Claude: it says so and ends the call" do
    LiveSetting.editable.update!(voice_engine_conversation_cap_usd: 0.1)
    LiveUsageEvent.record!(engine: "gpt_live_claude", operation: "voice_session", vendor: "openai_live", model: "gpt-live-1",
                           seconds: 600, live_conversation: @conversation)
    claude = LiveConversationHelpers::FakeClaude.new

    result = LiveConversations::ClaudeDelegate.call(@conversation, delegation_id: "d", client: claude)

    assert result.end_call
    assert_match(/spend cap/, result.text)
    assert_empty claude.requests
  end

  test "Claude failing is said aloud and recorded, not raised" do
    claude = LiveConversationHelpers::FakeClaude.new(responses: [ LiveConversations::ClaudeClient::Error.new("Claude: overloaded") ])

    result = LiveConversations::ClaudeDelegate.call(@conversation, delegation_id: "d", client: claude)

    assert_match(/couldn't reach my reasoning backend/, result.text)
    assert_not result.end_call
    assert_equal "Claude: overloaded", LiveUsageEvent.find_by!(operation: "delegation").error
  end

  test "the Claude model is a Live setting" do
    LiveSetting.editable.update!(voice_claude_model: "claude-opus-5-5")
    claude = LiveConversationHelpers::FakeClaude.new(responses: [ LiveConversationHelpers::FakeClaude.text("Done.", model: "claude-opus-5-5") ])

    LiveConversations::ClaudeDelegate.call(@conversation, delegation_id: "d", client: claude)

    assert_equal "claude-opus-5-5", claude.requests.sole["model"]
    assert_equal "claude-opus-5-5", LiveUsageEvent.sole.model
  end

  test "a long answer is split under GPT-Live's 500-token append limit" do
    chunks = LiveConversations::ClaudeDelegate.chunk("This is one sentence of the answer. " * 120)

    assert_operator chunks.size, :>, 1
    assert chunks.all? { |chunk| chunk.length <= LiveConversations::ClaudeDelegate::CHUNK_CHARS }
    assert_equal ("This is one sentence of the answer. " * 120).squish, chunks.join(" ")

    run_on = "word " * 700 # one 3,500-character sentence
    split = LiveConversations::ClaudeDelegate.chunk(run_on)
    assert split.all? { |chunk| chunk.length <= LiveConversations::ClaudeDelegate::CHUNK_CHARS }
    assert_equal run_on.squish, split.join(" "), "nothing of a long sentence is dropped"
  end
end
