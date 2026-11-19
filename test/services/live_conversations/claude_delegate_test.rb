# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class LiveConversations::ClaudeDelegateTest < ActiveSupport::TestCase
  setup do
    @conversation = create_live_conversation(mode: "voice", voice_engine: "gpt_live_claude")
    @conversation.turns.create!(role: "user", source: "spoken", content: "Hi there.")
  end

  def claude_failure(kind, message = "Claude Code: something")
    LiveConversations::ClaudeClient::Error.new(message, kind: kind, status: 1)
  end

  def capture_warn_logs
    io = StringIO.new
    logger = ActiveSupport::Logger.new(io)
    logger.level = Logger::WARN
    previous = Rails.logger
    Rails.logger = logger
    yield
    io.string
  ensure
    Rails.logger = previous
  end

  test "one Claude Code run on the configured model, with the thread, the delegation's instructions and a token for its tools" do
    claude = LiveConversationHelpers::FakeClaude.new(responses: [
      LiveConversationHelpers::FakeClaude.text("You're on the Sonnet model. Speed is normal.", turns: 2, input: 4_200, output: 80, cache_write: 3_000)
    ])

    result = LiveConversations::ClaudeDelegate.call(@conversation, delegation_id: "item_del_1",
                                                    pending_user_text: "What model are you on?", client: claude)

    assert_equal "You're on the Sonnet model. Speed is normal.", result.text
    assert_equal [ "You're on the Sonnet model. Speed is normal." ], result.chunks
    assert_not result.end_call
    assert_equal 2, result.rounds

    request = claude.requests.sole
    assert_equal "claude-sonnet-5-5", request["model"]
    assert_includes request["system"], "You are answering a delegation"
    assert_includes request["system"], "zimmer_live"
    assert_includes request["system"], "a goodbye without it leaves the microphone open"
    assert_includes request["prompt"], "Them: Hi there."
    assert_includes request["prompt"], "What model are you on?"
    claims = LiveConversations::DelegationToken.verify(request["mcp_token"])
    assert_equal [ @conversation.id, "item_del_1" ], [ claims.live_conversation_id, claims.delegation_id ]

    row = LiveUsageEvent.find_by!(operation: "delegation")
    assert_equal [ "anthropic", "claude-sonnet-5-5", 4_200, 80, 3_000 ], row.values_at(:vendor, :model, :input_tokens, :output_tokens, :cache_write_tokens)
    assert_equal "subscription", row.billing_basis
    assert_equal "claude_code", row.details["via"]
    assert row.latency_ms
    # 4200*2 + 80*10 + 3000*2.5 per million
    assert_in_delta 0.0167, row.cost_usd.to_f, 0.000001
    assert_in_delta row.cost_usd.to_f, result.cost_usd, 0.000001
    assert_equal 0, result.billed_usd
  end

  test "the Claude model is a Live setting, Opus included, and nothing quieter is substituted" do
    LiveSetting.editable.update!(voice_claude_model: "claude-opus-5-5")
    claude = LiveConversationHelpers::FakeClaude.new(responses: [ LiveConversationHelpers::FakeClaude.text("Done.", model: "claude-opus-5-5") ])

    LiveConversations::ClaudeDelegate.call(@conversation, delegation_id: "d", client: claude)

    assert_equal "claude-opus-5-5", claude.requests.sole["model"]
    assert_equal "claude-opus-5-5", LiveUsageEvent.sole.model
  end

  test "Claude Code not signed in is said as that, logged at WARN and on the ledger, and not retried on another model" do
    LiveSetting.editable.update!(voice_claude_model: "claude-opus-5-5")
    claude = LiveConversationHelpers::FakeClaude.new(responses: [ claude_failure(:auth, "Claude Code: Not logged in · Please run /login") ])

    logs = capture_warn_logs { @result = LiveConversations::ClaudeDelegate.call(@conversation, delegation_id: "d", client: claude) }

    assert_match(/isn't signed in on Zimmer's subscription/, @result.text)
    assert_match(/tools are fine/, @result.text)
    assert_no_match(/API key/i, @result.text)
    assert_not @result.end_call
    assert_equal 1, claude.requests.size
    row = LiveUsageEvent.find_by!(operation: "delegation")
    assert_equal "claude-opus-5-5", row.model
    assert_equal "Claude Code: Not logged in · Please run /login", row.error
    assert_equal "auth", row.details["kind"]
    assert_match(/\[live\.claude\] delegation failed kind=auth exit=1 model=claude-opus-5-5 .*Not logged in/, logs)
  end

  test "each failure kind is spoken as what it was" do
    { rate_limited: /rate limited or overloaded/, timeout: /took too long/, max_turns: /more steps/, failed: /Claude failed on that one/ }.each do |kind, said|
      claude = LiveConversationHelpers::FakeClaude.new(responses: [ claude_failure(kind) ])
      result = LiveConversations::ClaudeDelegate.call(@conversation, delegation_id: "d-#{kind}", client: claude)
      assert_match said, result.text
      assert_no_match(/reasoning backend/, result.text)
    end
  end

  test "no Claude Code account is not spoken as a backend failure: it is a 503 for the dock" do
    without_claude_code_account

    assert_raises(LiveConversations::ClaudeClient::NotConfiguredError) do
      LiveConversations::ClaudeDelegate.call(@conversation, delegation_id: "d")
    end
  end

  # What LiveDelegationMcpController writes when Claude calls hang_up.
  def hang_up_during(claude, delegation_id)
    conversation = @conversation
    claude.define_singleton_method(:run) do |**params|
      LiveUsageEvent.record!(engine: "gpt_live_claude", live_conversation: conversation, operation: "tool_call", vendor: "zimmer",
                             model: "hang_up", count: 1, details: { delegation_id: delegation_id })
      super(**params)
    end
    claude
  end

  test "a hang-up Claude made through the tools ends the call once the goodbye is said" do
    claude = hang_up_during(LiveConversationHelpers::FakeClaude.new(responses: [ LiveConversationHelpers::FakeClaude.text("Bye for now.") ]), "d")

    result = LiveConversations::ClaudeDelegate.call(@conversation, delegation_id: "d", client: claude)

    assert result.end_call
    assert result.hung_up
    assert_equal "Bye for now.", result.text
  end

  test "a hang-up still ends the call when the run fails after it, and another delegation's hang-up does not" do
    claude = hang_up_during(LiveConversationHelpers::FakeClaude.new(responses: [ claude_failure(:max_turns) ]), "d1")
    assert LiveConversations::ClaudeDelegate.call(@conversation, delegation_id: "d1", client: claude).end_call

    other = LiveConversationHelpers::FakeClaude.new(responses: [ LiveConversationHelpers::FakeClaude.text("Here you go.") ])
    assert_not LiveConversations::ClaudeDelegate.call(@conversation, delegation_id: "d2", client: other).end_call
  end

  test "a failed run's spend is on the ledger, and running out of steps is said as that" do
    error = LiveConversations::ClaudeClient::Error.new("Claude Code: error_max_turns", kind: :max_turns, status: 0,
                                                         usage: { "input_tokens" => 1_000_000, "output_tokens" => 0 })
    result = LiveConversations::ClaudeDelegate.call(@conversation, delegation_id: "d",
                                                    client: LiveConversationHelpers::FakeClaude.new(responses: [ error ]))

    assert_match(/more steps than I can take on a call/, result.text)
    row = LiveUsageEvent.find_by!(operation: "delegation")
    assert_equal 1_000_000, row.input_tokens
    assert_operator row.cost_usd.to_f, :>, 0
  end

  test "a second delegation while one is running says so instead of starving the first one's tool calls" do
    stub_const_running = LiveConversations::ClaudeDelegate::RUNNING
    stub_const_running[:count] = LiveConversations::ClaudeDelegate::MAX_CONCURRENT
    claude = LiveConversationHelpers::FakeClaude.new

    result = LiveConversations::ClaudeDelegate.call(@conversation, delegation_id: "d", client: claude)

    assert_match(/still working on the last request/, result.text)
    assert_empty claude.requests
    assert_equal "busy", LiveUsageEvent.find_by!(operation: "delegation").details["kind"]
  ensure
    stub_const_running[:count] = 0
  end

  test "the slot is released after a run, failed or not" do
    LiveConversations::ClaudeDelegate.call(@conversation, delegation_id: "a",
                                           client: LiveConversationHelpers::FakeClaude.new(responses: [ claude_failure(:failed) ]))
    LiveConversations::ClaudeDelegate.call(@conversation, delegation_id: "b",
                                           client: LiveConversationHelpers::FakeClaude.new(responses: [ LiveConversationHelpers::FakeClaude.text("Ok.") ]))

    assert_equal 0, LiveConversations::ClaudeDelegate::RUNNING[:count]
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

  test "a delegation's billing basis is the client's: Claude on an API key is metered, billed, and counted by the cap" do
    LiveSetting.editable.update!(voice_engine_conversation_cap_usd: 0.1)
    answer = LiveConversationHelpers::FakeClaude.text("Done.", input: 100_000)
    on_key = LiveConversationHelpers::FakeClaude.new(responses: [ answer ], billing_basis: "metered")

    result = LiveConversations::ClaudeDelegate.call(@conversation, delegation_id: "d1", client: on_key)

    row = LiveUsageEvent.find_by!(operation: "delegation")
    assert_equal "metered", row.billing_basis
    assert_in_delta row.cost_usd.to_f, result.billed_usd, 0.000001
    assert LiveConversations::SpendGuard.check(engine: "gpt_live_claude", conversation: @conversation).blocked?
  end

  test "the same delegation on the subscription bills nothing and leaves the cap alone" do
    LiveSetting.editable.update!(voice_engine_conversation_cap_usd: 0.1)
    answer = LiveConversationHelpers::FakeClaude.text("Done.", input: 100_000)
    on_plan = LiveConversationHelpers::FakeClaude.new(responses: [ answer ])

    result = LiveConversations::ClaudeDelegate.call(@conversation, delegation_id: "d1", client: on_plan)

    assert_equal "subscription", LiveUsageEvent.find_by!(operation: "delegation").billing_basis
    assert_equal 0, result.billed_usd
    assert_not LiveConversations::SpendGuard.check(engine: "gpt_live_claude", conversation: @conversation).blocked?
  end
end
