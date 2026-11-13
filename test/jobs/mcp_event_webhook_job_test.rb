# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# McpEventWebhookJob on its own: what it fires, what it declines, and that whatever it does not
# fire is left for the catch-up poll — the property at-least-once delivery rests on.
class McpEventWebhookJobTest < ActiveJob::TestCase
  include McpEventCatalogHelper

  setup do
    @server = FakeEventsMcpServer.start
    stub_events_catalog_server(@server.url)
    @trigger = Trigger.create!(
      name: "Webhook job", status: "enabled", agent_root_name: "zimmer", prompt_template: "Event {{event_id}}",
      trigger_conditions_attributes: [ { condition_type: "mcp_event",
                                         configuration: { "server" => "slack-zimmer", "event_name" => FakeEventsMcpServer::EVENT_NAME } } ]
    )
    @condition = @trigger.trigger_conditions.first
    McpEventTriggerPollerJob.perform_now # baseline
    @row = McpEventWebhookSubscription.build_for(@condition, base_url: "https://zimmer.test")
      .tap { |row| row.assign_attributes(state: "verified", verified_at: Time.current, subscribed_at: Time.current, refresh_before: 6.hours.from_now) }
    @row.save!
  end

  teardown { @server.stop }

  def spawned
    Session.for_trigger(@trigger.id).order(:id)
  end

  def publish(ts)
    @server.publish(channel_id: "C1", ts: ts)
    @server.last_event.slice("eventId", "name", "timestamp", "data")
  end

  test "an event held by a pending session gives its claim back, and the catch-up poll fires it" do
    @trigger.update!(skip_if_pending_session: true)
    first = publish("7.000001")
    McpEventWebhookJob.perform_now(@row.id, first)
    assert_equal 1, spawned.count

    second = publish("7.000002")
    McpEventWebhookJob.perform_now(@row.id, second)
    assert_equal 1, spawned.count, "held behind the pending session"
    assert_equal 1, TriggerEventClaim.count, "the held event's claim was given back"

    spawned.first.update_columns(status: "archived")
    @condition.update_columns(last_polled_at: 1.hour.ago)
    McpEventTriggerPollerJob.perform_now
    assert_equal [ "slack:C1:7.000001", "slack:C1:7.000002" ], spawned.map { |session| session.metadata["mcp_event_id"] },
      "the poll fired the held event and skipped the one push already fired"
  end

  test "a spawn that raises is reported and leaves the event to the poll" do
    Trigger.any_instance.stubs(:create_session!).raises(RuntimeError, "boom")
    ErrorReporter.expects(:report_exception).with(instance_of(RuntimeError), anything).once
    McpEventWebhookJob.perform_now(@row.id, publish("8.000001"))
    assert_equal 0, TriggerEventClaim.count

    Trigger.any_instance.unstub(:create_session!)
    @condition.update_columns(last_polled_at: 1.hour.ago)
    McpEventTriggerPollerJob.perform_now
    assert_equal 1, spawned.count
  end

  test "nothing fires for a subscription that is no longer live, or a malformed event" do
    @trigger.update!(status: "disabled")
    McpEventWebhookJob.perform_now(@row.id, publish("9.000001"))
    @trigger.update!(status: "enabled")
    McpEventWebhookJob.perform_now(@row.id, { "eventId" => "has spaces", "data" => {} })
    McpEventWebhookJob.perform_now(-1, publish("9.000002"))
    assert_equal 0, spawned.count
  end

  test "a trigger made unfenced behind the validation is reported, not fired" do
    @trigger.update_column(:prompt_template, "Do: {{event.text}}")
    ErrorReporter.expects(:report_exception).with(instance_of(McpEvents::Firing::UnfireableTrigger), anything).once
    McpEventWebhookJob.perform_now(@row.id, publish("10.000001"))
    assert_equal 0, spawned.count
  end
end
