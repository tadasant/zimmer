# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# McpEventSubscriptionsJob against FakeEventsMcpServer over real HTTP: when it subscribes, when it
# refreshes, when it unsubscribes, and what it leaves alone.
class McpEventSubscriptionsJobTest < ActiveJob::TestCase
  include McpEventCatalogHelper

  BASE_URL = "https://zimmer.test"

  setup do
    @server = FakeEventsMcpServer.start
    @server.delivery = %w[webhook poll]
    stub_events_catalog_server(@server.url)
    McpEvents.stubs(:webhook_base_url).returns(BASE_URL)
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new

    @trigger = Trigger.create!(
      name: "MCP events webhook", status: "enabled", agent_root_name: "zimmer", prompt_template: "{{event_id}}",
      trigger_conditions_attributes: [ { condition_type: "mcp_event",
                                         configuration: { "server" => "slack-zimmer", "event_name" => FakeEventsMcpServer::EVENT_NAME,
                                                          "arguments" => { "addressed_to_bot" => true } } } ]
    )
    @condition = @trigger.trigger_conditions.first
  end

  teardown do
    Rails.cache = @original_cache
    @server.stop
  end

  def subscribes
    @server.calls_to("events/subscribe")
  end

  test "subscribes once, then leaves a fresh grant alone" do
    McpEventSubscriptionsJob.perform_now
    McpEventSubscriptionsJob.perform_now

    assert_equal 1, subscribes.size
    params = subscribes.sole.params
    assert_equal({ "addressed_to_bot" => true }, params["arguments"])
    assert_nil params["cursor"], "an unbaselined condition subscribes from now"
    row = McpEventWebhookSubscription.sole
    assert_equal [ "subscribed", @condition.id ], [ row.state, row.trigger_condition_id ]
    assert_in_delta 6.hours.from_now, row.refresh_before, 5
    assert_equal "subscribed", @condition.reload.mcp_event_delivery["state"]
  end

  test "an event type that does not offer webhook stays poll-only" do
    @server.delivery = %w[poll]
    McpEventSubscriptionsJob.perform_now

    assert_empty subscribes
    assert_equal 0, McpEventWebhookSubscription.count
    assert_equal({ "state" => "poll-only" }, @condition.reload.mcp_event_delivery)
  end

  test "without a public https base URL nothing subscribes, and existing rows are retired" do
    McpEventSubscriptionsJob.perform_now
    McpEvents.stubs(:webhook_base_url).returns(nil)

    McpEventSubscriptionsJob.perform_now
    assert_equal 1, @server.calls_to("events/unsubscribe").size
    assert_equal 0, McpEventWebhookSubscription.count
  end

  test "refreshes before refreshBefore, with the row's own cursor, keeping the URL and secret" do
    McpEventSubscriptionsJob.perform_now
    row = McpEventWebhookSubscription.sole
    row.update_columns(cursor: "seq:7", state: "verified", verified_at: 1.hour.ago)

    travel_to(row.refresh_before - 20.minutes) { McpEventSubscriptionsJob.perform_now }

    assert_equal 2, subscribes.size
    first, refresh = subscribes.map(&:params)
    assert_equal "seq:7", refresh["cursor"]
    assert_equal first["delivery"], refresh["delivery"]
    assert_equal "verified", row.reload.state
  end

  test "a refresh reporting suspended delivery shows suspended, with only the category" do
    McpEventSubscriptionsJob.perform_now
    row = McpEventWebhookSubscription.sole
    @server.delivery_status = { "active" => false, "lastError" => "http_4xx", "failedSince" => 1.hour.ago.iso8601 }

    travel_to(row.refresh_before - 1.minute) { McpEventSubscriptionsJob.perform_now }

    row.reload
    assert_equal "suspended", row.state
    assert_equal "delivery suspended by the server (http_4xx)", row.last_error
    assert_not row.healthy?
  end

  test "a failed subscribe backs off as poll-only, naming the error category and not the server's text" do
    @server.refuse_subscribe = [ -32027, "<script>endpoint said 302 Found</script>", { "reason" => "challenge_failed" } ]
    McpEventSubscriptionsJob.perform_now

    row = McpEventWebhookSubscription.sole
    assert_equal [ "failed", 1, "subscribe failed: callback_endpoint_error (challenge_failed)" ], [ row.state, row.failures, row.last_error ]
    assert_in_delta 1.minute.from_now, row.next_attempt_at, 5
    assert_equal "poll-only", @condition.reload.mcp_event_delivery["state"]

    McpEventSubscriptionsJob.perform_now
    assert_equal 1, subscribes.size, "backing off"

    @server.refuse_subscribe = nil
    travel_to(2.minutes.from_now) { McpEventSubscriptionsJob.perform_now }
    assert_equal [ "subscribed", 0, nil ], row.reload.then { |r| [ r.state, r.failures, r.last_error ] }
  end

  test "disabling the trigger unsubscribes and deletes the row" do
    McpEventSubscriptionsJob.perform_now
    url = subscribes.sole.params.dig("delivery", "url")
    @trigger.update!(status: "disabled")

    McpEventSubscriptionsJob.perform_now

    unsubscribe = @server.calls_to("events/unsubscribe").sole.params
    assert_equal [ FakeEventsMcpServer::EVENT_NAME, { "addressed_to_bot" => true }, url ],
      [ unsubscribe["name"], unsubscribe["arguments"], unsubscribe.dig("delivery", "url") ]
    assert_equal 0, McpEventWebhookSubscription.count
  end

  test "editing the subscription unsubscribes the old one and subscribes the new one at a new URL" do
    McpEventSubscriptionsJob.perform_now
    old_url = subscribes.sole.params.dig("delivery", "url")
    @condition.update!(configuration: @condition.configuration.merge("arguments" => {}))

    McpEventSubscriptionsJob.perform_now

    assert_equal old_url, @server.calls_to("events/unsubscribe").sole.params.dig("delivery", "url")
    new_row = McpEventWebhookSubscription.sole
    assert_equal({}, new_row.arguments)
    assert_not_equal old_url, new_row.callback_url
    assert_equal({}, subscribes.last.params["arguments"])
  end

  test "editing only the template keeps the subscription" do
    McpEventSubscriptionsJob.perform_now
    @trigger.update!(prompt_template: "{{event_id}} again")

    McpEventSubscriptionsJob.perform_now
    assert_empty @server.calls_to("events/unsubscribe")
    assert_equal 1, McpEventWebhookSubscription.count
  end

  test "deleting the trigger keeps the row long enough to unsubscribe it" do
    McpEventSubscriptionsJob.perform_now
    @trigger.destroy!
    assert_nil McpEventWebhookSubscription.sole.trigger_condition_id

    McpEventSubscriptionsJob.perform_now
    assert_equal 1, @server.calls_to("events/unsubscribe").size
    assert_equal 0, McpEventWebhookSubscription.count
  end

  test "an unsubscribe the server cannot match (NotFound) still deletes the row; a failing one is retried" do
    McpEventSubscriptionsJob.perform_now
    @server.subscriptions.clear
    @trigger.update!(status: "disabled")
    McpEventSubscriptionsJob.perform_now
    assert_equal 0, McpEventWebhookSubscription.count

    @trigger.update!(status: "enabled")
    McpEventSubscriptionsJob.perform_now
    @trigger.update!(status: "disabled")
    @server.refuse = [ -32025, "ResourceExhausted" ]
    McpEventSubscriptionsJob.perform_now
    row = McpEventWebhookSubscription.sole
    assert_equal "unsubscribe failed: resource_exhausted", row.last_error

    @server.refuse = nil
    travel_to(2.minutes.from_now) { McpEventSubscriptionsJob.perform_now }
    assert_equal 0, McpEventWebhookSubscription.count
  end

  test "the poller polls a verified condition only every fifteen minutes, and any other every minute" do
    McpEventTriggerPollerJob.perform_now
    McpEventSubscriptionsJob.perform_now
    polls = -> { @server.polls.size }

    assert_difference polls, 1 do
      travel_to(2.minutes.from_now) { McpEventTriggerPollerJob.perform_now }
    end

    McpEventWebhookSubscription.sole.update_columns(state: "verified", verified_at: Time.current)
    assert_no_difference polls do
      travel_to(5.minutes.from_now) { McpEventTriggerPollerJob.perform_now }
    end
    assert_difference polls, 1 do
      travel_to(20.minutes.from_now) { McpEventTriggerPollerJob.perform_now }
    end
  end
end
