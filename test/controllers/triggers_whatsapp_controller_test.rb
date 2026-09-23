# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class TriggersWhatsappControllerTest < ActionDispatch::IntegrationTest
  CHAT = "120363012345678901@g.us"

  setup do
    ServersConfig.stubs(:exists?).returns(true)
    AgentRootsConfig.stubs(:names).returns(%w[zimmer wedding-planning])
    @api_key = "test_api_key_12345"
    ENV["API_KEYS"] = @api_key
  end

  teardown do
    Mocha::Mockery.instance.teardown
  end

  test "the new-trigger form offers WhatsApp and renders its fields" do
    get new_trigger_path(type: "whatsapp")

    assert_response :success
    assert_select "option[value=whatsapp][selected]"
    assert_select "[data-trigger-form-target=whatsappConfig]:not(.hidden)"
    assert_select "select[name=?]", "trigger[trigger_conditions_attributes][0][configuration][mode]"
  end

  test "the form creates a whatsapp condition from the fields it renders" do
    post triggers_path, params: { trigger: {
      name: "Wedding planner chat",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "{{text|untrusted}}",
      reuse_session: "1",
      trigger_conditions_attributes: {
        "0" => { condition_type: "whatsapp", configuration: {
          chat_id: CHAT, chat_name: "Wedding", mode: "addressed", keywords: "zimmer\nassistant", include_from_me: "0"
        } }
      }
    } }

    trigger = Trigger.last
    assert_redirected_to trigger_path(trigger)
    condition = trigger.trigger_conditions.sole
    assert_equal "whatsapp", condition.condition_type
    assert_equal CHAT, condition.whatsapp_chat_id
    assert condition.whatsapp_addressed_only?
    assert_equal %w[zimmer assistant], condition.whatsapp_keywords
    assert_not condition.whatsapp_include_from_me?
  end

  test "whatsapp_chats is a 503 when WhatsApp is not configured" do
    WhatsappService.stubs(:configured?).returns(false)

    get whatsapp_chats_triggers_path

    assert_response :service_unavailable
    assert_includes response.parsed_body["error"], "WHATSAPP_MCP_URL"
  end

  test "whatsapp_chats lists the bridge's chats" do
    WhatsappService.stubs(:configured?).returns(true)
    WhatsappService.any_instance.stubs(:list_chats).returns([ { "id" => CHAT, "name" => "Wedding", "is_group" => true } ])

    get whatsapp_chats_triggers_path

    assert_response :success
    assert_equal [ { "id" => CHAT, "name" => "Wedding", "is_group" => true } ], response.parsed_body["chats"]
  end

  test "whatsapp_chats reports a bridge error" do
    WhatsappService.stubs(:configured?).returns(true)
    WhatsappService.any_instance.stubs(:list_chats).raises(WhatsappService::Error, "whatsapp_list_chats: could not reach MCP server")

    get whatsapp_chats_triggers_path

    assert_response :service_unavailable
    assert_includes response.parsed_body["error"], "could not reach"
  end

  test "the API lists chats and creates a whatsapp trigger" do
    WhatsappService.stubs(:configured?).returns(true)
    WhatsappService.any_instance.stubs(:list_chats).returns([ { "id" => CHAT, "name" => "Wedding", "is_group" => true, "participant_count" => 3 } ])

    get whatsapp_chats_api_v1_triggers_path, headers: { "X-API-Key" => @api_key }
    assert_response :success
    assert_equal 3, response.parsed_body["chats"].first["participant_count"]

    post api_v1_triggers_path, headers: { "X-API-Key" => @api_key }, params: {
      name: "Wedding planner chat (API)",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "{{text|untrusted}}",
      trigger_conditions_attributes: [
        { condition_type: "whatsapp", configuration: { chat_id: CHAT, mode: "listen", keywords: [ "zimmer" ] } }
      ]
    }, as: :json

    assert_response :created
    assert_equal "listen", Trigger.find_by!(name: "Wedding planner chat (API)").trigger_conditions.sole.whatsapp_mode
  end
end
