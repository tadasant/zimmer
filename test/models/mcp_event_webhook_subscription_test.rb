# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class McpEventWebhookSubscriptionTest < ActiveSupport::TestCase
  include McpEventCatalogHelper

  setup do
    @server = FakeEventsMcpServer.start
    stub_events_catalog_server(@server.url)
    trigger = Trigger.create!(
      name: "Model", status: "enabled", agent_root_name: "zimmer", prompt_template: "{{event_id}}",
      trigger_conditions_attributes: [ { condition_type: "mcp_event",
                                         configuration: { "server" => "slack-zimmer", "event_name" => FakeEventsMcpServer::EVENT_NAME } } ]
    )
    @condition = trigger.trigger_conditions.first
    @row = McpEventWebhookSubscription.build_for(@condition, base_url: "https://zimmer.test/")
    @row.save!
  end

  teardown { @server.stop }

  test "build_for mints a token URL and an encrypted whsec_ secret that round-trips" do
    assert_match(%r{\Ahttps://zimmer\.test/webhooks/mcp_events/[A-Za-z0-9_-]{32}\z}, @row.callback_url)
    assert_match(/\Awhsec_/, @row.secret)
    assert_not_includes @row.secret_ciphertext, @row.secret
    assert @row.matches?(@condition, base_url: "https://zimmer.test")
    assert_not @row.matches?(@condition, base_url: "https://elsewhere.test")
  end

  test "a secret that no longer decrypts reads as nil" do
    @row.update_column(:secret_ciphertext, "garbage--not-a-message")
    assert_nil @row.reload.secret
  end

  test "state, display state and health" do
    assert_equal [ "pending", "poll-only", false ], [ @row.state, @row.display_state, @row.healthy? ]

    @row.update!(state: "subscribed", subscribed_at: Time.current, refresh_before: 6.hours.from_now)
    assert_equal [ "subscribed", false ], [ @row.display_state, @row.healthy? ]

    @row.note_signed_request!(remote_id: "sub_1", delivered: true)
    @row.reload
    assert_equal [ "verified", "verified", true, "sub_1" ], [ @row.state, @row.display_state, @row.healthy?, @row.remote_id ]

    travel_to(@row.refresh_before + 1.minute) do
      assert_equal [ "suspended", false ], [ @row.display_state, @row.healthy? ], "a lapsed grant is not push"
    end
    travel_to(8.hours.from_now) { assert_equal "suspended", @row.display_state }
    @row.update!(refresh_before: 1.day.from_now)
    travel_to(8.hours.from_now) do
      assert_equal [ "subscribed", false ], [ @row.display_state, @row.healthy? ], "proof of a working route expires"
    end

    @row.update!(state: "failed")
    assert_equal "poll-only", @row.display_state
  end

  test "a signed request before the subscribe answers records proof without claiming a state" do
    @row.note_signed_request!
    assert_equal "pending", @row.reload.state
    assert_not_nil @row.verified_at
  end
end
