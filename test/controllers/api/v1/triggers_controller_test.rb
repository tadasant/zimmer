require "test_helper"

class Api::V1::TriggersControllerTest < ActionDispatch::IntegrationTest
  setup do
    @valid_api_key = "test_api_key_12345"
    @headers = { "X-API-Key" => @valid_api_key }
    ENV["API_KEYS"] = @valid_api_key
    @trigger = triggers(:enabled_slack_trigger)
  end

  teardown do
    ENV.delete("API_KEYS")
  end

  # Authentication tests
  test "should return 401 without API key" do
    get api_v1_triggers_path
    assert_response :unauthorized
  end

  # Index tests
  test "should return list of triggers" do
    get api_v1_triggers_path, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    assert json.key?("triggers")
    assert json.key?("pagination")
    assert json["triggers"].is_a?(Array)
    assert json["triggers"].length > 0
  end

  test "should filter triggers by condition_type" do
    get api_v1_triggers_path, params: { condition_type: "slack" }, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    json["triggers"].each do |trigger|
      conditions = trigger["conditions"]
      assert conditions.any? { |c| c["condition_type"] == "slack" }
    end
  end

  test "should filter triggers by status" do
    get api_v1_triggers_path, params: { status: "enabled" }, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    json["triggers"].each do |trigger|
      assert_equal "enabled", trigger["status"]
    end
  end

  test "should paginate triggers" do
    get api_v1_triggers_path, params: { per_page: 2 }, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    assert json["triggers"].length <= 2
    assert json["pagination"]["per_page"], 2
  end

  # Show tests
  test "should return single trigger with recent sessions" do
    get api_v1_trigger_path(@trigger), headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    assert json.key?("trigger")
    assert json.key?("recent_sessions")
    assert_equal @trigger.id, json["trigger"]["id"]
    assert_equal @trigger.name, json["trigger"]["name"]
  end

  test "should return trigger with conditions instead of trigger_type" do
    get api_v1_trigger_path(@trigger), headers: @headers
    assert_response :success

    json = JSON.parse(response.body)["trigger"]
    expected_fields = %w[id name status agent_root_name prompt_template
      goal reuse_session mcp_servers conditions sessions_created_count
      created_at updated_at]

    expected_fields.each do |field|
      assert json.key?(field), "Expected field '#{field}' to be present"
    end

    # Should have conditions array
    assert json["conditions"].is_a?(Array)
    assert json["conditions"].length > 0

    # Each condition should have expected fields
    condition = json["conditions"].first
    assert condition.key?("id")
    assert condition.key?("condition_type")
    assert condition.key?("configuration")
    assert condition.key?("description")
  end

  test "should return 404 for nonexistent trigger" do
    get api_v1_trigger_path(999999), headers: @headers
    assert_response :not_found
  end

  # Create tests
  test "should create slack trigger with conditions" do
    assert_difference("Trigger.count", 1) do
      post api_v1_triggers_path, params: {
        name: "New Slack Trigger",
        agent_root_name: "zimmer",
        prompt_template: "Check this: {{link}}",
        trigger_conditions_attributes: [
          {
            condition_type: "slack",
            configuration: { channel_id: "C123456", channel_name: "test", event_type: "new_message" }
          }
        ]
      }, headers: @headers
    end

    assert_response :created
    json = JSON.parse(response.body)
    assert_equal "New Slack Trigger", json["trigger"]["name"]
    assert_equal "enabled", json["trigger"]["status"]
    assert json["trigger"]["conditions"].any? { |c| c["condition_type"] == "slack" }
  end

  test "should create schedule trigger with conditions" do
    assert_difference("Trigger.count", 1) do
      post api_v1_triggers_path, params: {
        name: "Hourly Check",
        agent_root_name: "zimmer",
        prompt_template: "Run hourly check at {{time}}",
        trigger_conditions_attributes: [
          {
            condition_type: "schedule",
            configuration: { interval: 1, unit: "hours" }
          }
        ]
      }, headers: @headers
    end

    assert_response :created
    json = JSON.parse(response.body)
    assert json["trigger"]["conditions"].any? { |c| c["condition_type"] == "schedule" }
  end

  test "should create ao_event trigger with conditions" do
    assert_difference("Trigger.count", 1) do
      post api_v1_triggers_path, params: {
        name: "Zimmer Event Trigger",
        agent_root_name: "zimmer",
        prompt_template: "Session needs input: {{event}}",
        trigger_conditions_attributes: [
          {
            condition_type: "ao_event",
            configuration: { event_name: "session_needs_input" }
          }
        ]
      }, headers: @headers
    end

    assert_response :created
    json = JSON.parse(response.body)
    assert json["trigger"]["conditions"].any? { |c| c["condition_type"] == "ao_event" }
  end

  test "should create ao_event trigger for session_failed event" do
    assert_difference("Trigger.count", 1) do
      post api_v1_triggers_path, params: {
        name: "Session Failed Handler",
        agent_root_name: "zimmer",
        prompt_template: "Session failed: {{event}}",
        trigger_conditions_attributes: [
          {
            condition_type: "ao_event",
            configuration: { event_name: "session_failed" }
          }
        ]
      }, headers: @headers
    end

    assert_response :created
    json = JSON.parse(response.body)
    condition = json["trigger"]["conditions"].find { |c| c["condition_type"] == "ao_event" }
    assert_equal "session_failed", condition["configuration"]["event_name"]
  end

  test "should create ao_event trigger with watched_session_id" do
    target = sessions(:needs_input)
    watched = sessions(:waiting)

    assert_difference("Trigger.count", 1) do
      post api_v1_triggers_path, params: {
        name: "Wake on watched session",
        agent_root_name: "zimmer",
        prompt_template: "Watched reached state: {{event}}",
        reuse_session: true,
        last_session_id: target.id,
        trigger_conditions_attributes: [
          {
            condition_type: "ao_event",
            configuration: {
              event_name: "session_needs_input",
              watched_session_id: watched.id
            }
          }
        ]
      }, headers: @headers
    end

    assert_response :created
    json = JSON.parse(response.body)
    condition = json["trigger"]["conditions"].find { |c| c["condition_type"] == "ao_event" }
    assert_equal watched.id, condition["configuration"]["watched_session_id"]
  end

  test "should reject ao_event trigger with invalid watched_session_id" do
    target = sessions(:needs_input)

    assert_no_difference("Trigger.count") do
      post api_v1_triggers_path, params: {
        name: "Invalid watched id",
        agent_root_name: "zimmer",
        prompt_template: "Bad: {{event}}",
        reuse_session: true,
        last_session_id: target.id,
        trigger_conditions_attributes: [
          {
            condition_type: "ao_event",
            configuration: {
              event_name: "session_needs_input",
              watched_session_id: 999_999_999
            }
          }
        ]
      }, headers: @headers
    end

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert json["messages"].join.include?("does not reference an existing session"),
      "Expected validation error mentioning missing session, got: #{json['messages'].inspect}"
  end

  test "should reject trigger without name" do
    assert_no_difference("Trigger.count") do
      post api_v1_triggers_path, params: {
        agent_root_name: "zimmer",
        prompt_template: "test",
        trigger_conditions_attributes: [
          { condition_type: "slack", configuration: { channel_id: "C123" } }
        ]
      }, headers: @headers
    end

    assert_response :unprocessable_entity
  end

  test "should create trigger with mcp_servers" do
    post api_v1_triggers_path, params: {
      name: "With Servers",
      agent_root_name: "zimmer",
      prompt_template: "test: {{link}}",
      mcp_servers: [ "slack-workspace" ],
      trigger_conditions_attributes: [
        { condition_type: "slack", configuration: { channel_id: "C123", channel_name: "test" } }
      ]
    }, headers: @headers

    assert_response :created
    json = JSON.parse(response.body)
    assert_includes json["trigger"]["mcp_servers"], "slack-workspace"
  end

  # Update tests
  test "should update trigger" do
    patch api_v1_trigger_path(@trigger), params: {
      name: "Updated Name"
    }, headers: @headers

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal "Updated Name", json["trigger"]["name"]
  end

  # Delete tests
  test "should delete trigger" do
    assert_difference("Trigger.count", -1) do
      delete api_v1_trigger_path(@trigger), headers: @headers
    end

    assert_response :no_content
  end

  test "should return 404 when deleting nonexistent trigger" do
    delete api_v1_trigger_path(999999), headers: @headers
    assert_response :not_found
  end

  # Toggle tests
  test "should toggle trigger from enabled to disabled" do
    assert @trigger.enabled?

    post toggle_api_v1_trigger_path(@trigger), headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    assert_equal "disabled", json["trigger"]["status"]
  end

  test "should toggle trigger from disabled to enabled" do
    disabled_trigger = triggers(:disabled_slack_trigger)
    assert disabled_trigger.disabled?

    post toggle_api_v1_trigger_path(disabled_trigger), headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    assert_equal "enabled", json["trigger"]["status"]
  end

  # Response format tests
  test "should return JSON with correct content type" do
    get api_v1_triggers_path, headers: @headers
    assert_equal "application/json; charset=utf-8", response.content_type
  end

  test "should include schedule_description for schedule conditions" do
    schedule_trigger = triggers(:enabled_schedule_trigger)
    get api_v1_trigger_path(schedule_trigger), headers: @headers
    assert_response :success

    json = JSON.parse(response.body)["trigger"]
    schedule_condition = json["conditions"].find { |c| c["condition_type"] == "schedule" }
    assert_not_nil schedule_condition
    assert schedule_condition.key?("description")
    assert_not_nil schedule_condition["description"]
  end

  # Per-session wake-up (last_session_id) tests
  test "should create trigger with last_session_id and transition target to waiting" do
    target = sessions(:needs_input)
    assert target.needs_input?

    post api_v1_triggers_path, params: {
      name: "Wake me later",
      agent_root_name: "zimmer",
      prompt_template: "Resume work",
      reuse_session: true,
      last_session_id: target.id,
      trigger_conditions_attributes: [
        {
          condition_type: "schedule",
          configuration: { scheduled_at: 1.hour.from_now.iso8601 }
        }
      ]
    }, headers: @headers

    assert_response :created
    json = JSON.parse(response.body)
    assert_equal target.id, json["trigger"]["last_session_id"]
    assert_equal true, json["trigger"]["reuse_session"]

    target.reload
    assert target.waiting?, "expected target session to be in waiting state, got #{target.status}"
  end

  test "should accept session_id as alias for last_session_id" do
    target = sessions(:needs_input)

    post api_v1_triggers_path, params: {
      name: "Wake me later via alias",
      agent_root_name: "zimmer",
      prompt_template: "Resume work",
      reuse_session: true,
      session_id: target.id,
      trigger_conditions_attributes: [
        {
          condition_type: "schedule",
          configuration: { scheduled_at: 1.hour.from_now.iso8601 }
        }
      ]
    }, headers: @headers

    assert_response :created
    json = JSON.parse(response.body)
    assert_equal target.id, json["trigger"]["last_session_id"]
  end

  test "should reject last_session_id without reuse_session" do
    target = sessions(:needs_input)

    assert_no_difference("Trigger.count") do
      post api_v1_triggers_path, params: {
        name: "Invalid per-session trigger",
        agent_root_name: "zimmer",
        prompt_template: "Resume",
        last_session_id: target.id,
        trigger_conditions_attributes: [
          { condition_type: "schedule", configuration: { scheduled_at: 1.hour.from_now.iso8601 } }
        ]
      }, headers: @headers
    end

    assert_response :unprocessable_entity
  end

  test "PATCH allows last_session_id on trigger without reuse_session (by design — create_new_session! uses this to track last-spawned session)" do
    # The validation is scoped to :create so that internal bookkeeping by
    # Trigger#create_new_session! (which writes last_session_id on every
    # trigger fire regardless of reuse_session) isn't blocked. Exercise that
    # an update-path write is allowed. Callers should not abuse this for
    # per-session wake-up on non-reuse triggers — that's what :create is for.
    target = sessions(:needs_input)

    patch api_v1_trigger_path(@trigger), params: { last_session_id: target.id }, headers: @headers

    assert_response :success
    @trigger.reload
    assert_equal target.id, @trigger.last_session_id
  end
end
