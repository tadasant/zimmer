# frozen_string_literal: true

# Shared setup for the Live Mode / Live Voice tests: a catalog that carries the
# two live roots, an OpenAI key, a scripted OpenAI client, and a real stdio MCP
# server (test/fixtures/files/live/clock_mcp_server.rb) for the self-enable path.
module LiveConversationHelpers
  CLOCK_SERVER = "test-clock"

  # Records every request and answers from a script, in order.
  class FakeOpenai
    attr_reader :chat_requests, :secret_requests

    def initialize(chat_responses: [], secret: { "value" => "ek_test_123", "expires_at" => 1_900_000_000 }, secret_failures: [])
      @chat_responses = chat_responses.dup
      @secret = secret
      @secret_failures = secret_failures.dup
      @chat_requests = []
      @secret_requests = []
    end

    def chat_completion(body)
      @chat_requests << body.deep_stringify_keys
      response = @chat_responses.shift || raise("FakeOpenai ran out of scripted chat responses")
      raise response if response.is_a?(Exception)

      response
    end

    def create_realtime_client_secret(body)
      @secret_requests << body.deep_stringify_keys
      failure = @secret_failures.shift
      raise failure if failure

      @secret
    end

    def self.text(content) = { "choices" => [ { "message" => { "role" => "assistant", "content" => content } } ] }

    def self.calls(*calls)
      {
        "choices" => [ {
          "message" => {
            "role" => "assistant", "content" => nil,
            "tool_calls" => calls.map.with_index do |(name, args), i|
              { "id" => "call_#{i}_#{name}", "type" => "function", "function" => { "name" => name, "arguments" => JSON.generate(args) } }
            end
          }
        } ]
      }
    end
  end

  def live_root(name, url: "https://github.com/example/live.git", default_mcp_servers: [ "zimmer" ])
    AgentRootsConfig::AgentRoot.new(name, {
      "url" => url, "default_branch" => "main", "subdirectory" => "agent-roots/#{name}",
      "default_mcp_servers" => default_mcp_servers
    })
  end

  # The catalog under test has no live roots, and Mocha cannot call through to
  # the real lookup for every other root a page resolves (the Quick Router's,
  # say) — so the two live names are answered by an override, and everything
  # else reaches the real catalog. Cleared after every test.
  module RootOverride
    def find(name)
      overrides = LiveConversationHelpers.root_overrides
      return overrides[name.to_s] if overrides&.key?(name.to_s)

      super
    end
  end

  class << self
    attr_accessor :root_overrides
  end

  def stub_live_roots(**overrides)
    LiveConversationHelpers.root_overrides = {
      "live-mode" => overrides.fetch(:text) { live_root("live-mode") },
      "live-voice" => overrides.fetch(:voice) { live_root("live-voice") }
    }
  end

  def stub_live_key(value = "sk-test-live")
    OpenaiClient.stubs(:api_key).returns(value)
  end

  def clock_server
    ServersConfig::Server.new(CLOCK_SERVER, {
      "title" => "Test clock", "description" => "Tells the time.", "type" => "stdio",
      "command" => RbConfig.ruby, "args" => [ Rails.root.join("test/fixtures/files/live/clock_mcp_server.rb").to_s ],
      "env" => { "CLOCK_GREETING" => "hello" }
    })
  end

  # Mocha cannot call through, so the catalog's own entries the bridge looks up
  # are captured first and stubbed back to themselves.
  def stub_clock_server(passthrough: %w[zimmer zimmer-sessions zimmer-self-session])
    real = passthrough.index_with { |name| ServersConfig.find(name) }
    server = clock_server
    real.each { |name, entry| ServersConfig.stubs(:find).with(name).returns(entry) }
    ServersConfig.stubs(:find).with(CLOCK_SERVER).returns(server)
    server
  end

  def create_live_conversation(mode: "text", status: LiveConversation::ACTIVE, mcp_servers: [ "zimmer" ], **attrs)
    LiveConversation.create!(
      mode: mode, status: status, agent_root: LiveConversations.mode(mode).agent_root,
      model: LiveConversations.mode(mode).model, instructions: "# Live\nBe brief.",
      mcp_servers: mcp_servers, **attrs
    )
  end
end

AgentRootsConfig.singleton_class.prepend(LiveConversationHelpers::RootOverride)
ActiveSupport::TestCase.include(LiveConversationHelpers)
ActiveSupport::TestCase.teardown { LiveConversationHelpers.root_overrides = nil }
