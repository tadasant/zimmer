require "test_helper"
require "mocha/minitest"
require "ostruct"

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

  test "should create a trigger with a burst cap and expose it in the payload" do
    post api_v1_triggers_path, params: {
      name: "Capped Alerts Trigger",
      agent_root_name: "zimmer",
      prompt_template: "Check this: {{link}}",
      max_sessions_per_minute: 3,
      trigger_conditions_attributes: [
        {
          condition_type: "slack",
          configuration: { channel_id: "C123456", channel_name: "alerts", event_type: "new_message" }
        }
      ]
    }, headers: @headers

    assert_response :created
    json = JSON.parse(response.body)
    assert_equal 3, json["trigger"]["max_sessions_per_minute"]
    assert_equal false, json["trigger"]["bursting"]
    assert_equal 3, Trigger.find(json["trigger"]["id"]).max_sessions_per_minute
  end

  test "should create a trigger with skip_if_pending_session and expose it in the payload" do
    post api_v1_triggers_path, params: {
      name: "Deduped Alerts Trigger",
      agent_root_name: "zimmer",
      prompt_template: "Check this: {{link}}",
      skip_if_pending_session: true,
      trigger_conditions_attributes: [
        { condition_type: "slack", configuration: { channel_id: "C1", channel_name: "alerts", event_type: "new_message" } }
      ]
    }, headers: @headers

    assert_response :created
    json = JSON.parse(response.body)
    assert_equal true, json["trigger"]["skip_if_pending_session"]
    assert Trigger.find(json["trigger"]["id"]).skip_if_pending_session
  end

  test "should reject a non-positive burst cap" do
    post api_v1_triggers_path, params: {
      name: "Bad Cap",
      agent_root_name: "zimmer",
      prompt_template: "Check this: {{link}}",
      max_sessions_per_minute: 0,
      trigger_conditions_attributes: [
        { condition_type: "slack", configuration: { channel_id: "C1", channel_name: "alerts", event_type: "new_message" } }
      ]
    }, headers: @headers

    assert_response :unprocessable_entity
    assert_includes JSON.parse(response.body)["messages"].join, "Max sessions per minute must be greater than 0"
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
  test "scheduling_class round-trips, and the payload reports both values" do
    trigger = triggers(:enabled_schedule_trigger)

    get api_v1_trigger_path(trigger), headers: @headers
    json = JSON.parse(response.body)["trigger"]
    assert_nil json["scheduling_class"]
    assert_equal "spot", json["effective_scheduling_class"], "a schedule trigger derives spot"

    patch api_v1_trigger_path(trigger), params: { scheduling_class: "priority" }, headers: @headers
    assert_response :success
    assert_equal SessionGenesis::PRIORITY, trigger.reload.scheduling_class
    assert_equal "priority", JSON.parse(response.body)["trigger"]["effective_scheduling_class"]
  end

  test "an unknown scheduling_class is rejected" do
    trigger = triggers(:enabled_schedule_trigger)

    patch api_v1_trigger_path(trigger), params: { scheduling_class: "whenever" }, headers: @headers

    assert_response :unprocessable_entity
    assert_nil trigger.reload.scheduling_class
  end

  # Invoke — the same fire the Invoke button on the trigger page performs.
  # ---------------------------------------------------------------------------

  def stub_session_creation
    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo",
      default_branch: "main",
      subdirectory: nil
    )
    AgentRootsConfig.stubs(:find!).returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)
    AgentSessionJob.stubs(:enqueue_with_prompt)
  end

  test "invoke requires an API key" do
    post invoke_api_v1_trigger_path(@trigger)
    assert_response :unauthorized
  end

  test "invoke creates a session linked to the trigger and increments its fire counter" do
    stub_session_creation
    before_count = @trigger.sessions_created_count

    assert_difference("Session.count", 1) do
      post invoke_api_v1_trigger_path(@trigger), headers: @headers
    end

    assert_response :created
    json = JSON.parse(response.body)

    session = Session.last
    assert_equal session.id, json["session"]["id"]
    assert_equal session.status, json["session"]["status"]
    assert_equal @trigger.id.to_s, session.metadata["trigger_id"].to_s
    assert_equal false, json["burst_notice"]
    assert_equal "Trigger \"#{@trigger.name}\" fired manually. Session created.", json["message"]

    assert_equal before_count + 1, @trigger.reload.sessions_created_count
    assert_equal before_count + 1, json["trigger"]["sessions_created_count"]
    assert_not_nil json["trigger"]["last_triggered_at"]
  end

  test "invoke interpolates the variables it is given and ignores the rest" do
    stub_session_creation

    post invoke_api_v1_trigger_path(@trigger),
      params: { variables: { link: "https://example.com/msg/1", channel: "eng-alerts", nonsense: "dropped" } },
      headers: @headers

    assert_response :created
    session = Session.last
    assert_includes session.prompt, "https://example.com/msg/1"
    assert_includes session.prompt, "#eng-alerts"
    assert_not_includes session.prompt, "dropped"
  end

  test "invoke accepts labels as an array, the one variable that is not a scalar" do
    stub_session_creation
    trigger = triggers(:enabled_slack_trigger)
    trigger.update!(prompt_template: "Labels: {{labels}}")

    post invoke_api_v1_trigger_path(trigger),
      params: { variables: { labels: [ "bug", "ready to merge" ] } },
      headers: @headers

    assert_response :created
    assert_equal "Labels: bug, ready to merge", Session.last.prompt
  end

  test "invoke without variables leaves the template's placeholders empty" do
    stub_session_creation

    post invoke_api_v1_trigger_path(@trigger), headers: @headers

    assert_response :created
    assert_not_includes Session.last.prompt, "{{link}}"
  end

  test "a session fired over the API carries the api genesis, not web_ui" do
    stub_session_creation

    post invoke_api_v1_trigger_path(@trigger), headers: @headers

    assert_response :created
    assert_equal SessionGenesis::API, Session.last.genesis
  end

  test "a disabled trigger can still be invoked by hand, as it can from the UI" do
    stub_session_creation
    trigger = triggers(:disabled_slack_trigger)

    assert_difference("Session.count", 1) do
      post invoke_api_v1_trigger_path(trigger), headers: @headers
    end

    assert_response :created
    assert_equal "disabled", trigger.reload.status, "invoking must not re-arm the trigger"
  end

  test "invoking a trigger that does not exist is a 404" do
    post invoke_api_v1_trigger_path(id: 999_999_999), headers: @headers

    assert_response :not_found
    json = JSON.parse(response.body)
    assert_equal "Not Found", json["error"]
  end

  test "over the burst cap invoke returns the burst-notice session, then 429" do
    stub_session_creation
    @trigger.update!(max_sessions_per_minute: 1)

    post invoke_api_v1_trigger_path(@trigger), headers: @headers
    assert_response :created
    assert_equal false, JSON.parse(response.body)["burst_notice"]

    post invoke_api_v1_trigger_path(@trigger), headers: @headers
    assert_response :created
    notice = JSON.parse(response.body)
    assert_equal true, notice["burst_notice"]
    assert_match(/burst-notice session it spawned instead/, notice["message"])

    assert_no_difference("Session.count") do
      post invoke_api_v1_trigger_path(@trigger), headers: @headers
    end
    assert_response :too_many_requests
    suppressed = JSON.parse(response.body)
    assert_equal "Burst suppressed", suppressed["error"]
    assert_match(/is in a burst/, suppressed["message"])
    assert suppressed["trigger"]["bursting"]
  end

  test "invoking a skip_if_pending_session trigger while a session is pending is a 409 that names it" do
    stub_session_creation
    @trigger.update!(skip_if_pending_session: true)

    post invoke_api_v1_trigger_path(@trigger), headers: @headers
    assert_response :created
    pending_id = JSON.parse(response.body)["session"]["id"]

    assert_no_difference("Session.count") do
      post invoke_api_v1_trigger_path(@trigger), headers: @headers
    end
    assert_response :conflict
    json = JSON.parse(response.body)
    assert_equal "No session created", json["error"]
    assert_equal pending_id, json["session"]["id"]
    assert_match(/already carries this intent/, json["message"])
  end

  test "a target session that cannot be reused is a 422 that names it, not a 201" do
    stub_session_creation
    target = sessions(:failed)
    @trigger.update!(reuse_session: true, last_session_id: target.id)
    Trigger.any_instance.stubs(:one_time_reuse_trigger?).returns(true)

    assert_no_difference("Session.count") do
      post invoke_api_v1_trigger_path(@trigger), headers: @headers
    end

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_equal "No session created", json["error"]
    assert_match(/no longer reusable/, json["message"])
    assert_equal target.id, json["session"]["id"]
  end

  test "invoke reports an unresolvable agent root as a 422 rather than a 500" do
    AgentRootsConfig.stubs(:find!).raises(AgentRootsConfig::AgentRootNotFoundError.new("Not found"))

    assert_no_difference("Session.count") do
      post invoke_api_v1_trigger_path(@trigger), headers: @headers
    end

    assert_response :unprocessable_entity
    assert_equal "Invalid agent_root", JSON.parse(response.body)["error"]
  end

  # --- Catalog artifact lists -------------------------------------------------

  test "should create trigger with catalog skills, hooks and plugins" do
    post api_v1_triggers_path, params: {
      name: "Equipped Trigger",
      agent_root_name: "zimmer",
      prompt_template: "test: {{link}}",
      catalog_skills: [ "zimmer-run-tests" ],
      catalog_hooks: [ "git-push-ci-reminder" ],
      catalog_plugins: [ "ci-workflow" ],
      trigger_conditions_attributes: [
        { condition_type: "slack", configuration: { channel_id: "C500", channel_name: "equipped" } }
      ]
    }, headers: @headers

    assert_response :created
    json = JSON.parse(response.body)["trigger"]
    assert_equal [ "zimmer-run-tests" ], json["catalog_skills"]
    assert_equal [ "git-push-ci-reminder" ], json["catalog_hooks"]
    assert_equal [ "ci-workflow" ], json["catalog_plugins"]

    trigger = Trigger.find(json["id"])
    assert_equal [ "zimmer-run-tests" ], trigger.catalog_skills, "the skill must be persisted, not only echoed"
    assert_equal [ "git-push-ci-reminder" ], trigger.catalog_hooks
    assert_equal [ "ci-workflow" ], trigger.catalog_plugins
  end

  test "should update a trigger's catalog skills" do
    patch api_v1_trigger_path(@trigger), params: { catalog_skills: [ "open-pr" ] }, headers: @headers

    assert_response :success
    assert_equal [ "open-pr" ], JSON.parse(response.body)["trigger"]["catalog_skills"]
    assert_equal [ "open-pr" ], @trigger.reload.catalog_skills
  end

  test "an omitted catalog list is left alone, an explicit empty one clears it" do
    @trigger.update!(catalog_skills: [ "open-pr" ], catalog_hooks: [ "git-push-ci-reminder" ])

    patch api_v1_trigger_path(@trigger), params: { catalog_skills: [] }, headers: @headers

    assert_response :success
    @trigger.reload
    assert_equal [], @trigger.catalog_skills
    assert_equal [ "git-push-ci-reminder" ], @trigger.catalog_hooks
  end

  test "should reject an unknown catalog skill id" do
    patch api_v1_trigger_path(@trigger), params: { catalog_skills: [ "not-a-skill" ] }, headers: @headers

    assert_response :unprocessable_entity
    assert_match(/invalid skill/i, response.body)
    assert_equal [], @trigger.reload.catalog_skills
  end

  test "should reject an unknown catalog hook id" do
    patch api_v1_trigger_path(@trigger), params: { catalog_hooks: [ "not-a-hook" ] }, headers: @headers

    assert_response :unprocessable_entity
    assert_match(/invalid hook/i, response.body)
  end

  test "should reject an unknown catalog plugin id" do
    patch api_v1_trigger_path(@trigger), params: { catalog_plugins: [ "not-a-plugin" ] }, headers: @headers

    assert_response :unprocessable_entity
    assert_match(/invalid plugin/i, response.body)
  end

  test "the trigger payload reports the three catalog lists" do
    @trigger.update!(catalog_skills: [ "open-pr" ], catalog_hooks: [ "git-push-ci-reminder" ], catalog_plugins: [ "ci-workflow" ])

    get api_v1_trigger_path(@trigger), headers: @headers

    assert_response :success
    json = JSON.parse(response.body)["trigger"]
    assert_equal [ "open-pr" ], json["catalog_skills"]
    assert_equal [ "git-push-ci-reminder" ], json["catalog_hooks"]
    assert_equal [ "ci-workflow" ], json["catalog_plugins"]
  end

  test "the index payload reports the catalog lists too" do
    @trigger.update!(catalog_skills: [ "open-pr" ])

    get api_v1_triggers_path, headers: @headers

    assert_response :success
    listed = JSON.parse(response.body)["triggers"].find { |t| t["id"] == @trigger.id }
    assert_equal [ "open-pr" ], listed["catalog_skills"]
    assert_equal [], listed["catalog_plugins"]
  end

  test "blank ids are dropped from a catalog list rather than persisted" do
    patch api_v1_trigger_path(@trigger), params: { catalog_skills: [ "", "open-pr" ] }, headers: @headers

    assert_response :success
    assert_equal [ "open-pr" ], @trigger.reload.catalog_skills
  end

  # --- enqueue_messages / resuscitate_archived --------------------------------

  test "enqueue_messages and resuscitate_archived land on a reuse trigger" do
    trigger = triggers(:weekly_schedule_trigger)

    patch api_v1_trigger_path(trigger),
          params: { enqueue_messages: true, resuscitate_archived: true }, headers: @headers

    assert_response :success
    json = JSON.parse(response.body)["trigger"]
    assert json["enqueue_messages"]
    assert json["resuscitate_archived"]
    trigger.reload
    assert trigger.enqueue_messages
    assert trigger.resuscitate_archived
  end

  test "enqueue_messages without reuse_session is cleared, and the payload reports the false that was stored" do
    refute @trigger.reuse_session

    patch api_v1_trigger_path(@trigger), params: { enqueue_messages: true }, headers: @headers

    assert_response :success
    refute JSON.parse(response.body)["trigger"]["enqueue_messages"],
           "the payload must report the stored false rather than echoing the request"
    refute @trigger.reload.enqueue_messages
  end

  test "should reject an unknown catalog skill id on create" do
    before = Trigger.count

    post api_v1_triggers_path, params: {
      name: "Bad Skill Trigger",
      agent_root_name: "zimmer",
      prompt_template: "test: {{link}}",
      catalog_skills: [ "not-a-skill" ],
      trigger_conditions_attributes: [
        { condition_type: "slack", configuration: { channel_id: "C501", channel_name: "bad" } }
      ]
    }, headers: @headers

    assert_response :unprocessable_entity
    assert_match(/invalid skill/i, response.body)
    assert_equal before, Trigger.count
  end
end
