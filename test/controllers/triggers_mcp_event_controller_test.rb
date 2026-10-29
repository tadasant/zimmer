# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class TriggersMcpEventControllerTest < ActionDispatch::IntegrationTest
  include McpEventCatalogHelper

  setup do
    @server = FakeEventsMcpServer.start
    stub_events_catalog_server(@server.url)
    AgentRootsConfig.stubs(:names).returns(%w[zimmer])
    @api_key = "test_api_key_12345"
    ENV["API_KEYS"] = @api_key
  end

  teardown do
    @server.stop
    Mocha::Mockery.instance.teardown
  end

  test "the new-trigger form offers MCP Event and renders its fields" do
    get new_trigger_path(type: "mcp_event")

    assert_response :success
    assert_select "option[value=mcp_event][selected]"
    assert_select "[data-trigger-form-target=mcpEventConfig]:not(.hidden)"
    assert_select "input[name=?]:not([disabled])", "trigger[trigger_conditions_attributes][0][configuration][server]"
    assert_select "textarea[name=?]:not([disabled])", "trigger[trigger_conditions_attributes][0][configuration][arguments]"
  end

  test "another condition type renders the MCP event fields hidden and disabled" do
    get new_trigger_path(type: "slack")

    assert_select "[data-trigger-form-target=mcpEventConfig].hidden"
    assert_select "input[name=?][disabled]", "trigger[trigger_conditions_attributes][0][configuration][server]"
  end

  test "the form creates an mcp_event condition from the JSON text it submits" do
    post triggers_path, params: { trigger: {
      name: "Slack via events",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "{{event_id}} {{event.text|untrusted}}",
      trigger_conditions_attributes: {
        "0" => { condition_type: "mcp_event", configuration: {
          server: "slack-zimmer", event_name: FakeEventsMcpServer::EVENT_NAME,
          arguments: '{"addressed_to_bot": true}', payload_filters: '{"user_id": ["U1"]}'
        } }
      }
    } }

    trigger = Trigger.last
    assert_redirected_to trigger_path(trigger)
    condition = trigger.trigger_conditions.sole
    assert_equal({ "addressed_to_bot" => true }, condition.mcp_event_arguments)
    assert_equal({ "user_id" => [ "U1" ] }, condition.mcp_event_payload_filters)

    get edit_trigger_path(trigger)
    assert_response :success
    assert_includes response.body, "{&quot;addressed_to_bot&quot;:true}"
  end

  test "the form refuses a template that writes a payload field bare" do
    assert_no_difference -> { Trigger.count } do
      post triggers_path, params: { trigger: {
        name: "Slack via events", status: "enabled", agent_root_name: "zimmer", prompt_template: "Do: {{event.text}}",
        trigger_conditions_attributes: { "0" => { condition_type: "mcp_event",
                                                  configuration: { server: "slack-zimmer", event_name: FakeEventsMcpServer::EVENT_NAME } } }
      } }
    end
    assert_includes response.body, "{{event.text|untrusted}}"
  end

  test "the API creates an mcp_event trigger with object arguments" do
    post api_v1_triggers_path, headers: { "X-API-Key" => @api_key }, params: {
      name: "Slack via events (API)",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "{{event_id}}",
      trigger_conditions_attributes: [ { condition_type: "mcp_event", configuration: {
        server: "slack-zimmer", event_name: FakeEventsMcpServer::EVENT_NAME,
        arguments: { addressed_to_bot: true, channel_ids: [ "C1", "C2" ] }, payload_filters: { user_id: [ "U1" ] }
      } } ]
    }, as: :json

    assert_response :created
    condition = Trigger.find_by!(name: "Slack via events (API)").trigger_conditions.sole
    assert_equal({ "addressed_to_bot" => true, "channel_ids" => [ "C1", "C2" ] }, condition.mcp_event_arguments)
  end

  test "both surfaces answer which servers publish events" do
    get mcp_event_sources_triggers_path(server: "slack-zimmer"), as: :json
    assert_response :success
    assert_equal [ FakeEventsMcpServer::EVENT_NAME ], response.parsed_body["sources"].sole["events"].map { |event| event["name"] }

    get mcp_event_sources_api_v1_triggers_path(server: "slack-zimmer"), headers: { "X-API-Key" => @api_key }, as: :json
    assert_response :success
    assert response.parsed_body["publishes_events"]

    get mcp_event_sources_api_v1_triggers_path(server: "no-such-server"), headers: { "X-API-Key" => @api_key }, as: :json
    assert_response :service_unavailable
  end
end
