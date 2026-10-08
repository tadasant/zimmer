# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class TriggersEmailControllerTest < ActionDispatch::IntegrationTest
  setup do
    ServersConfig.stubs(:exists?).returns(true)
    AgentRootsConfig.stubs(:names).returns(%w[zimmer])
    @api_key = "test_api_key_12345"
    ENV["API_KEYS"] = @api_key
  end

  teardown do
    Mocha::Mockery.instance.teardown
  end

  test "the new-trigger form offers email and renders its fields" do
    get new_trigger_path(type: "email")

    assert_response :success
    assert_select "option[value=email][selected]"
    assert_select "[data-trigger-form-target=emailConfig]:not(.hidden)"
    assert_select "input[name=?]:not([disabled])", "trigger[trigger_conditions_attributes][0][configuration][query]"
    assert_select "input[type=checkbox][name=?]", "trigger[trigger_conditions_attributes][0][configuration][include_automated]"
  end

  test "another condition type renders the email fields hidden and disabled" do
    get new_trigger_path(type: "slack")

    assert_select "[data-trigger-form-target=emailConfig].hidden"
    assert_select "input[name=?][disabled]", "trigger[trigger_conditions_attributes][0][configuration][query]"
  end

  test "the form creates an email condition from the fields it renders" do
    post triggers_path, params: { trigger: {
      name: "Zimmer inbox",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "{{text|untrusted}} ({{message_id}})",
      trigger_conditions_attributes: {
        "0" => { condition_type: "email", configuration: { query: "to:zimmer+bugs@example.com", include_automated: "0" } }
      }
    } }

    trigger = Trigger.last
    assert_redirected_to trigger_path(trigger)
    condition = trigger.trigger_conditions.sole
    assert_equal "email", condition.condition_type
    assert_equal "to:zimmer+bugs@example.com", condition.email_query
    assert_not condition.email_include_automated?

    get trigger_path(trigger)
    assert_response :success
    assert_includes response.body, "new mail matching to:zimmer+bugs@example.com"
  end

  test "the form refuses a template that writes the mail bare" do
    assert_no_difference -> { Trigger.count } do
      post triggers_path, params: { trigger: {
        name: "Zimmer inbox", status: "enabled", agent_root_name: "zimmer", prompt_template: "Answer this: {{text}}",
        trigger_conditions_attributes: { "0" => { condition_type: "email", configuration: { query: "" } } }
      } }
    end
    assert_includes response.body, "{{text|untrusted}}"
  end

  test "the API creates an email trigger" do
    post api_v1_triggers_path, headers: { "X-API-Key" => @api_key }, params: {
      name: "Zimmer inbox (API)",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "{{text|untrusted}} {{thread_id}}",
      trigger_conditions_attributes: [ { condition_type: "email", configuration: { query: "in:inbox", include_automated: true } } ]
    }, as: :json

    assert_response :created
    condition = Trigger.find_by!(name: "Zimmer inbox (API)").trigger_conditions.sole
    assert condition.email_include_automated?
  end
end
