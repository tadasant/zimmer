# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class McpEvents::ClientTest < ActiveSupport::TestCase
  include McpEventCatalogHelper

  setup do
    @server = FakeEventsMcpServer.start
    @client = McpEvents::Client.new(url: @server.url)
  end

  teardown { @server.stop }

  test "reads the extension off the server's declared capabilities" do
    assert @client.events_supported?

    @server.declares_events = false
    assert_not McpEvents::Client.new(url: @server.url).events_supported?
  end

  test "lists event types" do
    descriptor = @client.list_events.sole
    assert_equal FakeEventsMcpServer::EVENT_NAME, descriptor.name
    assert descriptor.pollable?
    assert_equal({ "addressed_to_bot" => { "type" => "boolean" } }, descriptor.input_schema["properties"])
  end

  test "polls from now, then from a cursor" do
    first = @client.poll(name: FakeEventsMcpServer::EVENT_NAME, arguments: {}, cursor: nil)
    assert_empty first.events
    assert_equal "seq:0", first.cursor

    @server.publish(channel_id: "C1", ts: "1.000001", text: "hi")
    result = @client.poll(name: FakeEventsMcpServer::EVENT_NAME, arguments: {}, cursor: first.cursor)
    event = result.events.sole
    assert_equal "slack:C1:1.000001", event.event_id
    assert_equal "hi", event.data["text"]
    assert_equal "seq:1", result.cursor
    assert_not result.truncated
  end

  test "an extension error carries its code" do
    @server.refuse = [ -32024, "Forbidden" ]
    error = assert_raises(McpApps::Client::RpcError) do
      @client.poll(name: FakeEventsMcpServer::EVENT_NAME, arguments: {}, cursor: nil)
    end
    assert_equal :forbidden, McpEvents.error_name(error.code)
  end

  test "refuses to poll a name it would not put in a header" do
    assert_raises(McpApps::Client::Error) { @client.poll(name: "bad name\r\n", arguments: {}, cursor: nil) }
  end

  test "Sources probes a catalog server with its resolved endpoint" do
    stub_events_catalog_server(@server.url)
    source = McpEvents::Sources.probe("slack-zimmer", cache: false)
    assert_equal "slack-zimmer", source.server_name
    assert_equal [ FakeEventsMcpServer::EVENT_NAME ], source.events.map(&:name)

    listing = McpEvents::Sources.listing(server: "slack-zimmer")
    assert listing["publishes_events"]

    assert_raises(McpEvents::Sources::Unavailable) { McpEvents::Sources.probe("no-such-server", cache: false) }
  end

  test "the refresh job writes the roster of servers that publish events" do
    original = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    fake = stub_events_catalog_server(@server.url)
    McpEvents::Sources.stubs(:candidates).returns([ fake ])

    McpEventSourcesRefreshJob.perform_now

    assert_equal [ "slack-zimmer" ], McpEvents::Sources.roster.map(&:server_name)
    assert_not_nil McpEvents::Sources.roster_swept_at
  ensure
    Rails.cache = original
  end
end
