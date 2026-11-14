# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"
require "socket"

class LiveConversations::ClaudeClientTest < ActiveSupport::TestCase
  test "calls Claude on Zimmer's current Claude Code account's token, as a Bearer token with the OAuth beta, and no API key" do
    previous = ENV.to_h.slice("ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "LIVE_ANTHROPIC_API_KEY")
    ENV["ANTHROPIC_API_KEY"] = "sk-ant-api-must-not-be-used"
    ENV.delete("LIVE_ANTHROPIC_API_KEY")
    messages = mock("messages")
    message = Struct.new(:to_json).new('{"content":[{"type":"text","text":"hi"}],"usage":{"input_tokens":3}}')
    messages.expects(:create).with do |params|
      params[:model] == "claude-sonnet-5-5" &&
        params[:request_options] == { timeout: 45, extra_headers: { "anthropic-beta" => "oauth-2025-04-20" } }
    end.returns(message)
    Anthropic::Client.expects(:new).with do |options|
      options[:auth_token] == claude_accounts(:primary).claude_access_token && !options.key?(:api_key)
    end.returns(stub(messages: messages))

    answer = LiveConversations::ClaudeClient.new.create_message(model: "claude-sonnet-5-5", max_tokens: 10, messages: [])

    assert_equal "hi", answer.dig("content", 0, "text")
  ensure
    %w[ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN LIVE_ANTHROPIC_API_KEY].each { |key| previous&.key?(key) ? ENV[key] = previous[key] : ENV.delete(key) }
  end

  # The real gem, on the wire: a local server records what arrives, with every
  # environment credential the gem could reach for set to something else.
  test "on the wire: Bearer with the pooled token and the OAuth beta, no x-api-key, whatever the environment holds" do
    previous = ENV.to_h.slice("ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN")
    ENV["ANTHROPIC_API_KEY"] = "sk-ant-api-env-must-not-be-used"
    ENV["ANTHROPIC_AUTH_TOKEN"] = "sk-ant-env-token-must-not-be-used"
    server = TCPServer.new("127.0.0.1", 0)
    headers = {}
    thread = Thread.new do
      socket = server.accept
      while (line = socket.gets) && line != "\r\n"
        name, value = line.split(":", 2)
        headers[name.downcase] = value.to_s.strip if value
      end
      socket.read(headers["content-length"].to_i)
      body = '{"id":"m","type":"message","role":"assistant","model":"claude-sonnet-5-5","content":[{"type":"text","text":"ok"}],' \
             '"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}'
      socket.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
      socket.close
    end

    answer = LiveConversations::ClaudeClient.new(base_url: "http://127.0.0.1:#{server.addr[1]}")
                                            .create_message(model: "claude-sonnet-5-5", max_tokens: 10, messages: [ { role: "user", content: "hi" } ])
    thread.join(5)

    assert_equal "ok", answer.dig("content", 0, "text")
    assert_equal "Bearer #{claude_accounts(:primary).claude_access_token}", headers["authorization"]
    assert_equal "oauth-2025-04-20", headers["anthropic-beta"]
    assert_nil headers["x-api-key"]
  ensure
    server&.close
    %w[ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN].each { |key| previous&.key?(key) ? ENV[key] = previous[key] : ENV.delete(key) }
  end

  test "a current account that cannot serve is unavailable, saying why, like the session spawn path" do
    account = claude_accounts(:primary)

    account.update!(status: :quota_exceeded)
    assert_equal "Zimmer's current Claude Code account is out of quota", LiveConversations::ClaudeClient.unavailable_reason
    assert_nil LiveConversations::ClaudeClient.access_token

    account.update!(status: :needs_reauth)
    assert_match(/needs re-authenticating/, LiveConversations::ClaudeClient.unavailable_reason)

    account.update!(status: :active, credential_rejected_at: Time.current, credential_verified_at: 1.hour.ago)
    assert_match(/needs re-authenticating/, LiveConversations::ClaudeClient.unavailable_reason)
    assert_not account.reload.usable_as_current?

    account.update!(credential_verified_at: Time.current)
    assert_nil LiveConversations::ClaudeClient.unavailable_reason
  end

  test "an account rotation reaches the next client: the token is read afresh" do
    claude_accounts(:primary).update!(is_current: false)
    claude_accounts(:secondary).update!(is_current: true)

    assert_equal claude_accounts(:secondary).claude_access_token, LiveConversations::ClaudeClient.access_token
  end

  test "no current account is NotConfigured, naming why" do
    without_claude_code_account

    error = assert_raises(LiveConversations::ClaudeClient::NotConfiguredError) { LiveConversations::ClaudeClient.new }
    assert_equal "Zimmer has no current Claude Code account", error.message
    assert_not LiveConversations::ClaudeClient.configured?
  end
end
