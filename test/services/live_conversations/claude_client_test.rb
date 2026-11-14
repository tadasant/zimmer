# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

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
