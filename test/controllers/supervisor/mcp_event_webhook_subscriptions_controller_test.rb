require "test_helper"
require "mocha/minitest"

module Supervisor
  class McpEventWebhookSubscriptionsControllerTest < ActionDispatch::IntegrationTest
    include McpEventCatalogHelper

    setup do
      @server = FakeEventsMcpServer.start
      stub_events_catalog_server(@server.url)
      trigger = Trigger.create!(
        name: "Supervised", status: "enabled", agent_root_name: "zimmer", prompt_template: "{{event_id}}",
        trigger_conditions_attributes: [ { condition_type: "mcp_event",
                                           configuration: { "server" => "slack-zimmer", "event_name" => FakeEventsMcpServer::EVENT_NAME } } ]
      )
      @row = McpEventWebhookSubscription.build_for(trigger.trigger_conditions.first, base_url: "https://zimmer.test")
      @row.assign_attributes(state: "failed", last_error: "subscribe failed: callback_endpoint_error (challenge_failed)")
      @row.save!
    end

    teardown { @server.stop }

    test "index and show render the state and never the secret" do
      get supervisor_mcp_event_webhook_subscriptions_url
      assert_response :success
      assert_match "callback_endpoint_error", response.body

      get supervisor_mcp_event_webhook_subscription_url(@row)
      assert_response :success
      assert_match FakeEventsMcpServer::EVENT_NAME, response.body
      assert_no_match @row.secret, response.body
      assert_no_match @row.secret_ciphertext.first(40), response.body
    end

    test "the panel is read-only" do
      actions = Rails.application.routes.routes
        .select { |route| route.defaults[:controller] == "supervisor/mcp_event_webhook_subscriptions" }
        .map { |route| route.defaults[:action] }

      assert_equal %w[index show], actions.sort
      assert_empty McpEventWebhookSubscriptionDashboard::FORM_ATTRIBUTES
    end
  end
end
