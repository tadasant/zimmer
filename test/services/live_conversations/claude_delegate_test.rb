# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"
require "socket"

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

  test "Claude failing is said aloud, recorded and logged at WARN, not raised" do
    claude = LiveConversationHelpers::FakeClaude.new(responses: [ LiveConversations::ClaudeClient::Error.new("Claude: overloaded") ])

    logs = capture_warn_logs { @result = LiveConversations::ClaudeDelegate.call(@conversation, delegation_id: "d", client: claude) }

    assert_match(/couldn't reach Claude/, @result.text)
    assert_not @result.end_call
    assert_equal "Claude: overloaded", LiveUsageEvent.find_by!(operation: "delegation").error
    assert_match(/\[live\.claude\] delegation failed status=nil .*message="Claude: overloaded"/, logs)
  end

  # What production saw: the subscription token refused for Opus outside
  # Claude Code, as a 429 whose message is just "Error".
  def subscription_refusal
    LiveConversations::ClaudeClient::Error.new("Claude: rate_limit_error", status: 429, api_message: "Error", credential_kind: :subscription)
  end

  def subscription = LiveConversations::ClaudeClient::Credential.new(kind: :subscription, secret: "sk-ant-oat-x")

  test "a model refused on the subscription falls back to Haiku for the rest of the delegation, logged and on the ledger" do
    LiveSetting.editable.update!(voice_claude_model: "claude-opus-5-5")
    claude = LiveConversationHelpers::FakeClaude.new(credential: subscription, responses: [
      subscription_refusal,
      LiveConversationHelpers::FakeClaude.tool("get_live_settings", model: "claude-haiku-5-5"),
      LiveConversationHelpers::FakeClaude.text("You're on the standard voice.", model: "claude-haiku-5-5")
    ])

    logs = capture_warn_logs { @result = LiveConversations::ClaudeDelegate.call(@conversation, delegation_id: "d", client: claude) }

    assert_equal "You're on the standard voice.", @result.text
    assert_equal %w[claude-opus-5-5 claude-haiku-5-5 claude-haiku-5-5], claude.requests.map { |r| r["model"] }
    rows = LiveUsageEvent.where(operation: "delegation").order(:id)
    assert_equal %w[claude-opus-5-5 claude-haiku-5-5 claude-haiku-5-5], rows.map(&:model)
    assert_equal 429, rows.first.details["status"]
    assert_equal "subscription", rows.first.details["credential"]
    assert_equal "claude-opus-5-5", rows.second.details["fallback_from"]
    assert rows.all? { |row| row.billing_basis == "subscription" }
    assert_equal "metered", LiveUsageEvent.find_by!(operation: "tool_call").billing_basis
    assert_match(/delegation failed status=429 model=claude-opus-5-5 credential=subscription/, logs)
    assert_match(/falling back to claude-haiku-5-5: claude-opus-5-5 was refused.*set LIVE_ANTHROPIC_API_KEY/, logs)
  end

  test "Haiku refused too is spoken as Claude refusing the credential, not as the tools being unreachable" do
    claude = LiveConversationHelpers::FakeClaude.new(credential: subscription, responses: [ subscription_refusal, subscription_refusal ])

    result = LiveConversations::ClaudeDelegate.call(@conversation, delegation_id: "d", client: claude)

    assert_match(/turned down Zimmer's Claude Code subscription/, result.text)
    assert_match(/tools are fine/, result.text)
    assert_match(/Anthropic API key/, result.text)
    assert_equal 2, claude.requests.size
    assert_equal %w[claude-sonnet-5-5 claude-haiku-5-5], LiveUsageEvent.where(operation: "delegation").order(:id).map(&:model)
  end

  test "a real rate limit (a message that says what) and any failure on the API key do not fall back" do
    limited = LiveConversations::ClaudeClient::Error.new("Claude: limit", status: 429, api_message: "Number of request tokens has exceeded your per-minute rate limit",
                                                         credential_kind: :subscription)
    claude = LiveConversationHelpers::FakeClaude.new(credential: subscription, responses: [ limited ])
    result = LiveConversations::ClaudeDelegate.call(@conversation, delegation_id: "d", client: claude)
    assert_match(/rate limited or overloaded/, result.text)
    assert_equal 1, claude.requests.size

    api_key = LiveConversations::ClaudeClient::Credential.new(kind: :api_key, secret: "sk-ant-api-x")
    refused = LiveConversations::ClaudeClient::Error.new("Claude: invalid x-api-key", status: 401, api_message: "invalid x-api-key", credential_kind: :api_key)
    claude = LiveConversationHelpers::FakeClaude.new(credential: api_key, responses: [ refused ])
    result = LiveConversations::ClaudeDelegate.call(@conversation, delegation_id: "d2", client: claude)
    assert_match(/refused Live Mode's credential/, result.text)
    assert_equal 1, claude.requests.size
  end

  test "Claude on the API key is metered on the ledger" do
    api_key = LiveConversations::ClaudeClient::Credential.new(kind: :api_key, secret: "sk-ant-api-x")
    claude = LiveConversationHelpers::FakeClaude.new(credential: api_key, responses: [ LiveConversationHelpers::FakeClaude.text("Done.", input: 1_000_000) ])

    result = LiveConversations::ClaudeDelegate.call(@conversation, delegation_id: "d", client: claude)

    row = LiveUsageEvent.sole
    assert_equal "metered", row.billing_basis
    assert_in_delta row.cost_usd.to_f, result.billed_usd, 0.000001
    assert_operator result.billed_usd, :>, 0
  end

  # End to end through the real gem: a stand-in for api.anthropic.com that
  # answers Opus the way production did on 2026-11-15 (429, message "Error")
  # and Haiku with an answer.
  test "end to end on the real client: Opus refused on the subscription, Haiku answers, the person hears it" do
    LiveSetting.editable.update!(voice_claude_model: "claude-opus-5-5")
    server = TCPServer.new("127.0.0.1", 0)
    seen = []
    acceptor = Thread.new do
      loop do
        socket = server.accept
        headers = {}
        while (line = socket.gets) && line != "\r\n"
          name, value = line.split(":", 2)
          headers[name.downcase] = value.to_s.strip if value
        end
        model = JSON.parse(socket.read(headers["content-length"].to_i))["model"]
        seen << [ model, headers["authorization"].to_s.start_with?("Bearer "), headers["anthropic-beta"] ]
        status, body =
          if model == "claude-haiku-5-5"
            [ "200 OK", { id: "m", type: "message", role: "assistant", model: model, stop_reason: "end_turn",
                          content: [ { type: "text", text: "Two sessions need you." } ], usage: { input_tokens: 9, output_tokens: 5 } }.to_json ]
          else
            [ "429 Too Many Requests", '{"type":"error","error":{"type":"rate_limit_error","message":"Error"},"request_id":"req_x"}' ]
          end
        socket.write("HTTP/1.1 #{status}\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
        socket.close
      end
    rescue IOError, Errno::EBADF
      nil
    end
    credential = LiveConversations::ClaudeClient.credential(chain: SecretProviders::Chain.new([ SecretProviders::Env.new({}) ]))
    client = LiveConversations::ClaudeClient.new(credential: credential, base_url: "http://127.0.0.1:#{server.addr[1]}")

    result = LiveConversations::ClaudeDelegate.call(@conversation, delegation_id: "d", pending_user_text: "What needs me?", client: client)

    assert_equal "Two sessions need you.", result.text
    assert_equal "claude-haiku-5-5", seen.last.first
    assert seen.all? { |_model, bearer, beta| bearer && beta == "oauth-2025-04-20" }
    rows = LiveUsageEvent.where(operation: "delegation").order(:id)
    assert_equal [ 429, nil ], rows.map { |row| row.details["status"] }
    assert_equal %w[claude-opus-5-5 claude-haiku-5-5], rows.map(&:model)
  ensure
    server&.close
    acceptor&.kill
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
