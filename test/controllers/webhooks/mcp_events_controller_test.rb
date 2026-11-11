# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# POST /webhooks/mcp_events/:token, end to end. McpEventSubscriptionsJob subscribes over real HTTP
# to FakeEventsMcpServer, which hands back the secret and URL Zimmer sent it the way a server
# would. The test then signs deliveries with that secret, as the server would, and posts them
# through routing, the controller, McpEventWebhookJob and Trigger#create_session!. After that the
# poller polls the same server, to show that an event arriving both ways fires once.
class Webhooks::McpEventsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include McpEventCatalogHelper

  BASE_URL = "https://zimmer.test"
  TEMPLATE = "Event {{event_id}}:\n{{event.text|untrusted}}"

  setup do
    @server = FakeEventsMcpServer.start
    @server.delivery = %w[webhook poll]
    stub_events_catalog_server(@server.url)
    McpEvents.stubs(:webhook_base_url).returns(BASE_URL)
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new

    @trigger = Trigger.create!(
      name: "Slack via MCP events webhook", status: "enabled", agent_root_name: "zimmer", prompt_template: TEMPLATE,
      trigger_conditions_attributes: [ { condition_type: "mcp_event",
                                         configuration: { "server" => "slack-zimmer", "event_name" => FakeEventsMcpServer::EVENT_NAME } } ]
    )
    @condition = @trigger.trigger_conditions.first
    McpEventTriggerPollerJob.perform_now # baseline the poll cursor
    McpEventSubscriptionsJob.perform_now
    @row = McpEventWebhookSubscription.sole
    @subscribe = @server.calls_to("events/subscribe").sole.params
  end

  teardown do
    Rails.cache = @original_cache
    @server.stop
  end

  def path_of(url)
    URI.parse(url).path
  end

  def deliver(body, secret: @subscribe.dig("delivery", "secret"), message_id: "msg_#{SecureRandom.hex(8)}",
              timestamp: Time.current.to_i.to_s, signature: :sign, path: path_of(@subscribe.dig("delivery", "url")))
    body = JSON.generate(body) unless body.is_a?(String)
    signature = Webhooks::StandardWebhooksSignature.sign(secret: secret, body: body, message_id: message_id, timestamp: timestamp) if signature == :sign
    headers = { "Content-Type" => "application/json", "webhook-id" => message_id, "webhook-timestamp" => timestamp,
                "webhook-signature" => signature, "X-MCP-Subscription-Id" => @row.remote_id }.compact
    post path, params: body, headers: headers
  end

  def spawned
    Session.for_trigger(@trigger.id)
  end

  test "the subscribe carries a fresh whsec_ secret, Zimmer's public URL, the poll cursor and a TTL" do
    delivery = @subscribe["delivery"]
    assert_equal "webhook", delivery["mode"]
    assert_match(%r{\Ahttps://zimmer\.test/webhooks/mcp_events/[A-Za-z0-9_-]{32}\z}, delivery["url"])
    assert_equal 32, Webhooks::StandardWebhooksSignature.key_bytes(delivery["secret"]).bytesize
    assert_equal @condition.reload.mcp_event_cursor, @subscribe["cursor"]
    assert_equal 6.hours.in_milliseconds, @subscribe["ttlMs"]
    assert_equal FakeEventsMcpServer::EVENT_NAME, @server.calls_to("events/subscribe").sole.headers["mcp-name"]

    assert_equal "subscribed", @row.state
    assert_not_includes @row.secret_ciphertext, delivery["secret"].delete_prefix("whsec_"), "the secret is stored encrypted"
    assert_equal delivery["secret"], @row.secret
  end

  test "the verification challenge is echoed, and marks the subscription verified" do
    deliver({ "type" => "verification", "challenge" => "nonce-123" })

    assert_response :ok
    assert_equal({ "challenge" => "nonce-123" }, response.parsed_body)
    assert_equal "verified", @row.reload.state
    assert_match(/\Asub_\h{16}\z/, @row.remote_id, "the id the subscribe response named")
    assert_equal "verified", @condition.reload.mcp_event_delivery["state"]
  end

  test "a signed event fires one session, and the same event polled afterwards fires nothing more" do
    @server.publish(channel_id: "C0WEBHOOK", ts: "1793400000.000100", text: "hello by push")
    event = @server.last_event

    assert_difference -> { spawned.count }, 1 do
      perform_enqueued_jobs(only: McpEventWebhookJob) { deliver(event) }
    end
    assert_response :ok
    session = spawned.sole
    assert_includes session.prompt, "Event slack:C0WEBHOOK:1793400000.000100:"
    assert_match(/\[begin untrusted event\.text \h{16}:/, session.prompt)
    assert_equal [ "mcp:slack-zimmer:slack:C0WEBHOOK:1793400000.000100", "mcp_event_webhook", session.id ],
      TriggerEventClaim.sole.then { |claim| [ claim.event_key, claim.claimed_via, claim.session_id ] }

    @row.reload
    assert_equal "verified", @row.state, "a signed delivery proves the path works"
    assert_equal event["cursor"], @row.cursor
    assert_not_nil @row.last_delivery_at

    # The catch-up poll sees the same event and finds the claim.
    @condition.update_columns(last_polled_at: 1.hour.ago)
    assert_no_difference -> { spawned.count } do
      McpEventTriggerPollerJob.perform_now
    end
    assert_equal "seq:1", @condition.reload.mcp_event_cursor
  end

  test "an event the poll fired first is not fired again when its webhook arrives" do
    @server.publish(channel_id: "C0POLLED", ts: "1793400000.000200")
    McpEventTriggerPollerJob.perform_now
    assert_equal 1, spawned.count

    assert_no_difference -> { spawned.count } do
      perform_enqueued_jobs(only: McpEventWebhookJob) { deliver(@server.last_event) }
    end
    assert_response :ok
  end

  test "a redelivery with the same webhook-id is acknowledged and not processed again" do
    @server.publish(channel_id: "C0RETRY", ts: "1793400000.000300")
    event = @server.last_event

    assert_enqueued_jobs 1, only: McpEventWebhookJob do
      deliver(event, message_id: "msg_retry_1")
      deliver(event, message_id: "msg_retry_1", timestamp: (Time.current.to_i + 30).to_s)
    end
    assert_response :ok
    assert_equal 1, WebhookDelivery.where(source: "mcp_events").count
  end

  test "every refusal is an empty 401: unknown token, wrong secret, stale timestamp, missing signature" do
    @server.publish(channel_id: "C0BAD", ts: "1793400000.000400")
    event = @server.last_event

    deliver(event, path: "/webhooks/mcp_events/#{SecureRandom.urlsafe_base64(24)}")
    assert_response :unauthorized
    assert_empty response.body

    deliver(event, secret: Webhooks::StandardWebhooksSignature.generate_secret)
    assert_response :unauthorized
    assert_empty response.body

    deliver(event, timestamp: 10.minutes.ago.to_i.to_s)
    assert_response :unauthorized

    deliver(event, signature: nil)
    assert_response :unauthorized

    deliver({ "type" => "verification", "challenge" => "x" }, secret: Webhooks::StandardWebhooksSignature.generate_secret)
    assert_response :unauthorized
    assert_empty response.body, "an unsigned challenge is never echoed"

    assert_equal 0, WebhookDelivery.count
    assert_equal "subscribed", @row.reload.state
    assert_enqueued_jobs 0, only: McpEventWebhookJob
  end

  test "a malformed token does not route at all" do
    post "/webhooks/mcp_events/short", params: "{}", headers: { "Content-Type" => "application/json" }
    assert_response :not_found
  end

  test "an event for a disabled trigger is refused with 410, which the server does not retry" do
    @trigger.update!(status: "disabled")
    @server.publish(channel_id: "C0OFF", ts: "1793400000.000500")

    deliver(@server.last_event)
    assert_response :gone
    assert_enqueued_jobs 0, only: McpEventWebhookJob
  end

  test "a terminated envelope returns the row to pending, and the next sweep subscribes again" do
    deliver({ "type" => "terminated", "error" => { "code" => -32024, "message" => "Forbidden", "data" => { "reason" => "Access revoked" } } })
    assert_response :ok
    @row.reload
    assert_equal [ "pending", "terminated by the server (forbidden)" ], [ @row.state, @row.last_error ]
    assert_equal "poll-only", @condition.reload.mcp_event_delivery["state"]

    McpEventSubscriptionsJob.perform_now
    assert_equal 2, @server.calls_to("events/subscribe").size
    assert_equal "verified", @row.reload.state, "the terminated envelope was itself a signed request on the URL"
  end

  test "a gap envelope keeps the fresh cursor" do
    deliver({ "type" => "gap", "cursor" => "seq:99" })
    assert_response :ok
    assert_equal "seq:99", @row.reload.cursor
  end

  test "an address over the rate limit gets 429 before its signature is looked at" do
    stub_const(Webhooks::McpEventsController, :RATE_LIMIT, 2) do
      3.times { deliver({ "type" => "verification", "challenge" => "x" }) }
    end
    assert_response :too_many_requests
  end

  private

  def stub_const(klass, name, value)
    original = klass.const_get(name)
    klass.send(:remove_const, name)
    klass.const_set(name, value)
    yield
  ensure
    klass.send(:remove_const, name)
    klass.const_set(name, original)
  end
end
