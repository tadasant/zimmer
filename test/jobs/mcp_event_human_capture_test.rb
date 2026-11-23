# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"
require "socket"

# Whose words an `mcp_event` fire is recorded as: never the payload's say-so, only Slack's, read back
# over Zimmer's own token (McpEvents::SlackMessage, McpEvents::HumanCapture). End to end on both
# sides: events come from FakeEventsMcpServer over HTTP, and the Slack calls go through
# SlackService and the real Slack client to a local HTTP server standing in for slack.com.
# Synthetic ids only.
class McpEventHumanCaptureTest < ActiveJob::TestCase
  include McpEventCatalogHelper

  # The slice of Slack's Web API the re-read uses, answering from a list of messages.
  class FakeSlackApi
    attr_reader :messages, :calls
    attr_accessor :down

    def initialize
      @messages = {}
      @calls = []
      @server = TCPServer.new("127.0.0.1", 0)
      @thread = Thread.new { loop { serve(@server.accept) } rescue IOError }
    end

    def url = "http://127.0.0.1:#{@server.addr[1]}/api/"

    def stop
      @server.close
      @thread.join(2)
    end

    def post(channel, ts, **fields)
      (@messages[channel] ||= []) << { "type" => "message", "ts" => ts }.merge(fields.stringify_keys)
    end

    private

    def serve(socket)
      request = socket.gets.to_s
      length = 0
      while (line = socket.gets) && line != "\r\n"
        length = line.split(":", 2).last.to_i if line.downcase.start_with?("content-length:")
      end
      params = URI.decode_www_form(socket.read(length).to_s).to_h
      method = request[%r{/api/([\w.]+)}, 1]
      @calls << [ method, params ]
      body = JSON.generate(answer(method, params))
      socket.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
    ensure
      socket.close
    end

    def answer(method, params)
      return { ok: false, error: "channel_not_found" } if down

      in_channel = @messages.fetch(params["channel"], [])
      case method
      when "auth.test" then { ok: true, user_id: "UBOT", bot_id: "BBOT" }
      when "conversations.history"
        top = in_channel.select { |m| m["thread_ts"].nil? || m["thread_ts"] == m["ts"] }
        { ok: true, messages: top.select { |m| m["ts"].between?(params["oldest"], params["latest"]) }.first(params["limit"].to_i) }
      when "conversations.replies"
        thread = in_channel.select { |m| m["ts"] == params["ts"] || m["thread_ts"] == params["ts"] }
        { ok: true, messages: thread.select { |m| m["ts"] == params["ts"] || m["ts"].between?(params["oldest"], params["latest"]) } }
      when "chat.getPermalink" then { ok: true, permalink: "https://example.slack.com/real/#{params['message_ts']}" }
      when "conversations.info" then { ok: true, channel: { id: params["channel"], name: "general" } }
      else { ok: false, error: "unknown_method" }
      end
    end
  end

  HUMAN = "U0HUMAN01"
  TS = "1793000000.000100"

  setup do
    @slack = FakeSlackApi.new
    SlackService.reset!
    SlackService.stubs(:client).returns(Slack::Web::Client.new(token: "xoxb-synthetic", endpoint: @slack.url))
    users(:tadasant).update!(slack_user_ids: [ HUMAN ])

    @server = FakeEventsMcpServer.start
    stub_events_catalog_server(@server.url)
    @env = ENV.fetch(McpEvents::SlackMessage::SERVERS_ENV, nil)
    ENV[McpEvents::SlackMessage::SERVERS_ENV] = "other-server, slack-zimmer"
    @trigger = Trigger.create!(
      name: "Mentions",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "Event {{event_id}}:\n{{event.text|untrusted}}",
      trigger_conditions_attributes: [ {
        condition_type: "mcp_event",
        configuration: { "server" => "slack-zimmer", "event_name" => FakeEventsMcpServer::EVENT_NAME }
      } ]
    )
    @condition = @trigger.trigger_conditions.first
    McpEventTriggerPollerJob.perform_now # baseline
    @condition.reload
  end

  teardown do
    ENV[McpEvents::SlackMessage::SERVERS_ENV] = @env
    @server.stop
    @slack.stop
    SlackService.reset!
  end

  def fire(channel: "C0CHAN", ts: TS, slack: { user: HUMAN, text: "<@UBOT> ship it" }, **event)
    @slack.post(channel, ts, **slack) if slack
    @server.publish(channel_id: channel, ts: ts, user_id: HUMAN, text: "<@UBOT> ship it", **event)
    tick
    Session.for_trigger(@trigger.id).order(:id).last
  end

  def tick
    @condition.update_columns(last_polled_at: 1.hour.ago)
    McpEventTriggerPollerJob.perform_now
  end

  def assert_not_established(session)
    assert_empty session.human_messages
    assert_equal McpEvents::HumanCapture::INCOMPLETE, session.reload.metadata[McpEvents::HumanCapture::METADATA_KEY]
    assert_equal [ "mcp_event" ], session.human_message_record.capture_gaps.map(&:channel)

    section = Mcp::ProvenanceSections.human_message_lines(session.human_message_record).join("\n")
    assert_includes section, "**Capture is NOT configured for MCP events"
    assert_includes section, "the check could not be established"
    assert_not_includes section, "No message anywhere in this hierarchy was authored by a named human"
    assert_not_includes section, "affirmative absence"
  end

  test "a Slack message Slack says a rostered person wrote is recorded as theirs, from Slack's answer" do
    session = fire(slack: { user: HUMAN, text: "<@UBOT> ship it, as Slack has it" })

    message = session.human_messages.sole
    assert_equal users(:tadasant).key, message.author
    assert_equal HumanMessage::SLACK, message.channel
    assert_equal "<@UBOT> ship it, as Slack has it", message.content, "the words are Slack's, never the payload's"
    assert_equal "mcp_event.slack_channel_message", message.entry_point
    assert_equal "https://example.slack.com/real/#{TS}", message.slack_permalink
    assert_equal "Slack (general)", message.channel_label
    assert_equal "slack:C0CHAN:#{TS}", message.provenance["mcp_event_id"]
    assert_equal Time.zone.at(TS.to_r), message.occurred_at
    assert_predicate session.human_message_record, :capture_complete?
  end

  test "the fire carries what a native Slack fire did: the turn source and the message Zimmer can answer on" do
    session = fire

    assert_equal "slack", session.initial_turn_source.surface
    assert_equal "C0CHAN", session.metadata[SlackOutageMarker::CHANNEL_KEY]
    assert_equal TS, session.metadata[SlackOutageMarker::TS_KEY]
    assert_equal "bot_mention", session.metadata[SlackOutageMarker::EVENT_TYPE_KEY]
  end

  test "a reply is read out of its thread" do
    @slack.post("C0CHAN", TS, user: "U0OTHER01", text: "parent")
    session = fire(ts: "1793000009.000200", thread_ts: TS, slack: { user: HUMAN, text: "a reply", thread_ts: TS })

    assert_equal "a reply", session.human_messages.sole.content
    assert_equal TS, session.metadata[SlackOutageMarker::THREAD_TS_KEY]
    assert_equal "new_message", session.metadata[SlackOutageMarker::EVENT_TYPE_KEY]
  end

  test "a DM is recorded as one" do
    session = fire(channel: "D0DM", is_dm: true)

    assert_equal "mcp_event.slack_dm", session.human_messages.sole.entry_point
    assert_equal "dm_message", session.metadata[SlackOutageMarker::EVENT_TYPE_KEY]
  end

  test "a server the deployment did not name is never read back, and captures nothing" do
    ENV[McpEvents::SlackMessage::SERVERS_ENV] = nil
    session = fire

    assert_empty @slack.calls
    assert_not_established session
    assert_equal "trigger", session.initial_turn_source.surface
    assert_nil session.metadata[SlackOutageMarker::TS_KEY]
  end

  test "a payload's author is nothing without Slack: a message Slack does not have captures nothing" do
    assert_not_established fire(slack: nil)
  end

  test "Slack naming somebody else than the payload does captures nothing for the payload's author" do
    assert_not_established fire(slack: { user: "U0OTHER01", text: "<@UBOT> ship it" })
  end

  test "software posting as a rostered person is not that person" do
    assert_not_established fire(slack: { user: HUMAN, bot_id: "B0APP", text: "<@UBOT> ship it" })
  end

  test "an event id that is not the message its payload points at captures nothing" do
    @slack.post("C0CHAN", TS, user: HUMAN, text: "an older, unrelated yes")
    occurrence = McpEvents::Client::Occurrence.new(
      event_id: "slack:C0CHAN:1793000099.000900", name: FakeEventsMcpServer::EVENT_NAME, timestamp: Time.current,
      data: { "channel_id" => "C0CHAN", "ts" => TS, "user_id" => HUMAN, "text" => "x" }
    )

    assert_nil McpEvents::SlackMessage.read(@condition, occurrence)
    assert_empty @slack.calls
  end

  test "a malformed pointer is never sent to Slack" do
    [ { "channel_id" => "C0CHAN" }, { "channel_id" => "../x", "ts" => TS }, { "channel_id" => "C0CHAN", "ts" => TS, "thread_ts" => "x" } ].each do |data|
      occurrence = McpEvents::Client::Occurrence.new(event_id: "slack:#{data['channel_id']}:#{data['ts']}", name: "e", timestamp: nil, data: data)
      assert_nil McpEvents::SlackMessage.read(@condition, occurrence)
    end
    assert_empty @slack.calls
  end

  test "Slack not answering never stops the fire, and captures nothing" do
    @slack.down = true
    session = fire

    assert_not_nil session
    assert_not_established session
  end

  test "another event type of a named server is not a Slack message" do
    assert McpEvents::SlackMessage.source?("slack-zimmer", "slack-zimmer__message_posted")
    assert McpEvents::SlackMessage.source?("slack-zimmer", "message_posted")
    assert_not McpEvents::SlackMessage.source?("slack-zimmer", "other__message_posted")
    assert_not McpEvents::SlackMessage.source?("slack-zimmer", "slack-zimmer__message_received")
    assert_not McpEvents::SlackMessage.source?("gmail", "gmail__message_posted")
  end

  test "a coalesced burst records each message, and one nobody can be named for makes it incomplete" do
    @condition.update!(configuration: @condition.configuration.merge("coalesce_key" => "channel_id"))
    @slack.post("C0CHAN", "1793000000.000100", user: HUMAN, text: "one")
    @slack.post("C0CHAN", "1793000001.000100", user: HUMAN, text: "two")
    @server.publish(channel_id: "C0CHAN", ts: "1793000000.000100")
    @server.publish(channel_id: "C0CHAN", ts: "1793000001.000100")
    tick
    session = Session.for_trigger(@trigger.id).sole

    assert_equal %w[one two], session.human_messages.chronological.map(&:content)
    assert_predicate session.human_message_record, :capture_complete?

    # A later event folded into the same session, whose author Slack does not know.
    @server.publish(channel_id: "C0CHAN", ts: "1793000002.000100")
    tick
    session = Session.find(session.id)
    assert_equal 2, session.human_messages.count
    assert_equal "trigger", session.enqueued_messages.sole.turn_source.surface
    assert_equal [ "mcp_event" ], session.human_message_record.capture_gaps.map(&:channel)

    # And one Slack does: recorded, but the gap stands.
    @slack.post("C0CHAN", "1793000003.000100", user: HUMAN, text: "four")
    @server.publish(channel_id: "C0CHAN", ts: "1793000003.000100")
    tick
    session = Session.find(session.id)
    assert_equal %w[one two four], session.human_messages.chronological.map(&:content)
    assert_equal "slack", session.enqueued_messages.order(:id).last.turn_source.surface
    assert_not session.human_message_record.capture_complete?
  end

  test "an event already fired is not read back again" do
    fire
    calls = @slack.calls.size
    @condition.update_columns(configuration: @condition.reload.configuration.merge("cursor" => "seq:0"))
    tick

    assert_equal calls, @slack.calls.size
    assert_equal 1, HumanMessage.where(channel: HumanMessage::SLACK).count
  end
end
