# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"
require "socket"

class LiveConversations::ClaudeClientTest < ActiveSupport::TestCase
  def env_chain(values = {}) = SecretProviders::Chain.new([ SecretProviders::Env.new(values) ])

  # A local server that records the request's headers and answers with
  # `status` and `body`.
  def with_recording_server(status: "200 OK", body: nil)
    body ||= '{"id":"m","type":"message","role":"assistant","model":"claude-sonnet-5-5","content":[{"type":"text","text":"ok"}],' \
             '"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}'
    server = TCPServer.new("127.0.0.1", 0)
    headers = {}
    # Every connection is answered: the gem retries a 429 once.
    acceptor = Thread.new do
      loop do
        socket = server.accept
        while (line = socket.gets) && line != "\r\n"
          name, value = line.split(":", 2)
          headers[name.downcase] = value.to_s.strip if value
        end
        socket.read(headers["content-length"].to_i)
        socket.write("HTTP/1.1 #{status}\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
        socket.close
      end
    rescue IOError, Errno::EBADF
      nil
    end
    yield "http://127.0.0.1:#{server.addr[1]}", headers
  ensure
    server&.close
    acceptor&.kill
  end

  test "LIVE_ANTHROPIC_API_KEY wins: x-api-key on the wire, no Bearer, no OAuth beta, even with no usable account" do
    claude_accounts(:primary).update!(status: :quota_exceeded)
    credential = LiveConversations::ClaudeClient.credential(chain: env_chain("LIVE_ANTHROPIC_API_KEY" => "sk-ant-api-live"))
    assert_equal :api_key, credential.first.kind
    assert_nil credential.last
    assert_not_includes credential.first.inspect, "sk-ant-api-live"
    assert_not_includes credential.first.pretty_inspect, "sk-ant-api-live"
    assert_not_includes credential.first.to_h.to_s, "sk-ant-api-live"

    with_recording_server do |url, headers|
      answer = LiveConversations::ClaudeClient.new(credential: credential, base_url: url)
                                              .create_message(model: "claude-opus-5-5", max_tokens: 10, messages: [ { role: "user", content: "hi" } ])
      assert_equal "ok", answer.dig("content", 0, "text")
      assert_equal "sk-ant-api-live", headers["x-api-key"]
      assert_nil headers["authorization"]
      assert_nil headers["anthropic-beta"]
    end
  end

  test "no key falls back to the subscription account" do
    credential, reason = LiveConversations::ClaudeClient.credential(chain: env_chain)
    assert_nil reason
    assert credential.subscription?
    assert_equal claude_accounts(:primary).claude_access_token, credential.secret
  end

  test "on the wire: the subscription refusal (429, message \"Error\") is named, with status and Anthropic's message" do
    body = '{"type":"error","error":{"type":"rate_limit_error","message":"Error"},"request_id":"req_1"}'
    with_recording_server(status: "429 Too Many Requests", body: body) do |url, _headers|
      client = LiveConversations::ClaudeClient.new(credential: LiveConversations::ClaudeClient.credential(chain: env_chain), base_url: url)
      error = assert_raises(LiveConversations::ClaudeClient::Error) do
        client.create_message(model: "claude-opus-5-5", max_tokens: 10, messages: [ { role: "user", content: "hi" } ])
      end
      assert_equal 429, error.status
      assert_equal "Error", error.api_message
      assert_equal :subscription, error.credential_kind
      assert error.subscription_refused?
      assert error.credential_refused?
    end
  end

  test "a real rate limit, or a 429 on the API key, is not a subscription refusal" do
    error_class = LiveConversations::ClaudeClient::Error
    assert_not error_class.new("x", status: 429, api_message: "Number of request tokens has exceeded your per-minute rate limit", credential_kind: :subscription).subscription_refused?
    assert_not error_class.new("x", status: 429, api_message: "Error", credential_kind: :api_key).credential_refused?
    assert error_class.new("x", status: 401, api_message: "invalid x-api-key", credential_kind: :api_key).credential_refused?
    assert error_class.new("x", status: 400, api_message: "This credential is only authorized for use with Claude Code", credential_kind: :subscription).credential_refused?
    assert_not error_class.new("x", status: 400, api_message: "messages: field required", credential_kind: :subscription).credential_refused?
    assert_not error_class.new("x").credential_refused?
  end
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
