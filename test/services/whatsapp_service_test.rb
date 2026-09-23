# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class WhatsappServiceTest < ActiveSupport::TestCase
  class FakeClient
    attr_reader :calls

    def initialize(tools:, results:)
      @tools = tools
      @results = results
      @calls = []
    end

    def tools_list
      @tools.map { |name| { "name" => name } }
    end

    def call_tool(name, arguments)
      @calls << [ name, arguments ]
      @results.fetch(name)
    end
  end

  def structured(json)
    { "structuredContent" => json, "content" => [ { "type" => "text", "text" => json.to_json } ] }
  end

  test "resolves gateway-namespaced tool names and parses messages oldest first" do
    client = FakeClient.new(
      tools: [ "whatsapp-zimmer__whatsapp_get_messages" ],
      results: {
        "whatsapp-zimmer__whatsapp_get_messages" => structured(
          "chat_id" => "1@g.us", "chat_name" => "Wedding", "has_more" => true,
          "messages" => [
            { "id" => "B", "timestamp" => 20, "text" => "second", "from_me" => true },
            { "id" => "A", "timestamp" => 10, "text" => "first", "sent_by_bridge" => true, "mentions_self" => true },
            { "timestamp" => 30 }
          ]
        )
      }
    )

    page = WhatsappService.new(client: client).get_messages("1@g.us", after: 5, limit: 999)

    assert_equal [ "whatsapp-zimmer__whatsapp_get_messages", { "chat_id" => "1@g.us", "limit" => 200, "after" => 5 } ], client.calls.first
    assert_equal %w[A B], page.messages.map(&:id)
    assert page.messages.first.sent_by_bridge
    assert page.messages.first.mentions_self
    assert page.messages.last.from_me
    assert page.has_more
    assert_equal "Wedding", page.chat_name
  end

  test "falls back to the JSON text item when there is no structuredContent" do
    client = FakeClient.new(
      tools: [ "whatsapp_status" ],
      results: { "whatsapp_status" => { "content" => [ { "type" => "text", "text" => { connected: true, paired: true }.to_json } ] } }
    )

    assert WhatsappService.new(client: client).ensure_ready!.ready?
  end

  test "ensure_ready! raises when the bridge is not linked" do
    client = FakeClient.new(tools: [ "whatsapp_status" ], results: { "whatsapp_status" => structured("connected" => true, "paired" => false) })

    error = assert_raises(WhatsappService::NotConnectedError) { WhatsappService.new(client: client).ensure_ready! }
    assert_includes error.message, "not paired"
  end

  test "a tool error surfaces as WhatsappService::Error" do
    client = FakeClient.new(
      tools: [ "whatsapp_list_chats" ],
      results: { "whatsapp_list_chats" => { "isError" => true, "content" => [ { "type" => "text", "text" => "socket closed" } ] } }
    )

    error = assert_raises(WhatsappService::Error) { WhatsappService.new(client: client).list_chats }
    assert_includes error.message, "socket closed"
  end

  test "a missing tool is an error, not a guess" do
    client = FakeClient.new(tools: [ "slack_post_message" ], results: {})
    assert_raises(WhatsappService::Error) { WhatsappService.new(client: client).status }
  end

  test "configured only with a URL, and the token falls back to STRAD_API_KEY" do
    chain = mock
    chain.stubs(:get).with("WHATSAPP_MCP_URL").returns("https://strad.example/mcp?servers=whatsapp-zimmer")
    chain.stubs(:get).with("WHATSAPP_MCP_TOKEN").returns(nil)
    chain.stubs(:get).with("STRAD_API_KEY").returns("strad-key")
    SecretProviders.stubs(:chain).returns(chain)

    assert WhatsappService.configured?
    assert_equal "strad-key", WhatsappService.token
  end

  test "not configured without a URL" do
    chain = mock
    chain.stubs(:get).returns(nil)
    SecretProviders.stubs(:chain).returns(chain)

    assert_not WhatsappService.configured?
  end
end
