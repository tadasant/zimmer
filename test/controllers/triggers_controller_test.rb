# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"
require "ostruct"

class TriggersControllerTest < ActionDispatch::IntegrationTest
  setup do
    @trigger = triggers(:enabled_slack_trigger)
    ServersConfig.stubs(:exists?).returns(true)
  end

  teardown do
    Mocha::Mockery.instance.teardown
  end

  test "should get index" do
    get triggers_path
    assert_response :success
    assert_select "h1", "Triggers"
  end

  test "should get new" do
    get new_trigger_path
    assert_response :success
    assert_select "h1", "New Trigger"
  end

  test "new form renders the lazy-loaded channel dropdown instead of free-text name and ID inputs" do
    get new_trigger_path
    assert_response :success

    # The Slack channel is now picked from a dropdown, backed by hidden fields.
    assert_select "select[data-trigger-form-target='channelSelect']", 1
    assert_select "input[type=hidden][name=?][data-trigger-form-target='channelId']",
                  "trigger[trigger_conditions_attributes][0][configuration][channel_id]"
    assert_select "input[type=hidden][name=?][data-trigger-form-target='channelName']",
                  "trigger[trigger_conditions_attributes][0][configuration][channel_name]"

    # No free-text channel-name input is rendered — the name is derived from the pick.
    assert_select "input[type=text][placeholder=?]", "Channel name (e.g., eng-ci)", false
  end

  test "edit form pre-selects the saved channel in the dropdown" do
    trigger = triggers(:enabled_slack_trigger)
    condition = trigger.trigger_conditions.slack.first

    get edit_trigger_path(trigger)
    assert_response :success

    # The saved channel is rendered as a pre-selected option so it survives even
    # before (or without) the async channel list loading.
    assert_select "select[data-trigger-form-target='channelSelect'] option[selected][value=?]",
                  condition.channel_id
    assert_select "input[type=hidden][data-trigger-form-target='channelId'][value=?]",
                  condition.channel_id
  end

  test "should get new with schedule type" do
    get new_trigger_path(type: "schedule")
    assert_response :success
    assert_select "h1", "New Trigger"
  end

  test "should get new with ao_event type" do
    get new_trigger_path(type: "ao_event")
    assert_response :success
    assert_select "h1", "New Trigger"
  end

  test "should create slack trigger with conditions" do
    assert_difference("Trigger.count") do
      post triggers_path, params: {
        trigger: {
          name: "New Test Trigger",
          status: "enabled",
          agent_root_name: "zimmer",
          prompt_template: "New message: {{link}}",
          mcp_servers: [],
          trigger_conditions_attributes: [
            {
              condition_type: "slack",
              configuration: {
                channel_id: "C123456",
                channel_name: "test-channel",
                event_type: "new_message"
              }
            }
          ]
        }
      }
    end

    assert_redirected_to trigger_path(Trigger.last)
    follow_redirect!
    assert_response :success
  end

  test "should create trigger with a burst cap, and treat a blank cap as unbounded" do
    post triggers_path, params: {
      trigger: {
        name: "Capped Alerts Trigger",
        status: "enabled",
        agent_root_name: "zimmer",
        prompt_template: "New alert: {{link}}",
        max_sessions_per_minute: "3",
        mcp_servers: [],
        trigger_conditions_attributes: [
          { condition_type: "slack", configuration: { channel_id: "C123456", channel_name: "alerts", event_type: "new_message" } }
        ]
      }
    }

    trigger = Trigger.find_by!(name: "Capped Alerts Trigger")
    assert_equal 3, trigger.max_sessions_per_minute

    # Clearing the field means "no limit", not zero.
    patch trigger_path(trigger), params: { trigger: { max_sessions_per_minute: "" } }
    assert_nil trigger.reload.max_sessions_per_minute
  end

  test "should reject a non-positive burst cap" do
    patch trigger_path(@trigger), params: { trigger: { max_sessions_per_minute: "0" } }

    assert_response :unprocessable_entity
    assert_nil @trigger.reload.max_sessions_per_minute
  end

  test "should create slack trigger with bot_mention event type" do
    assert_difference("Trigger.count") do
      post triggers_path, params: {
        trigger: {
          name: "Bot Mention Trigger",
          status: "enabled",
          agent_root_name: "zimmer",
          prompt_template: "Bot was mentioned: {{text}}",
          mcp_servers: [],
          trigger_conditions_attributes: [
            {
              condition_type: "slack",
              configuration: {
                channel_id: "",
                channel_name: "",
                event_type: "bot_mention"
              }
            }
          ]
        }
      }
    end

    trigger = Trigger.last
    assert_redirected_to trigger_path(trigger)
    condition = trigger.trigger_conditions.first
    assert_equal "slack", condition.condition_type
    assert_equal "bot_mention", condition.event_type
  end

  test "should create trigger with browser-style hash-indexed nested attributes" do
    # Browsers submit nested attributes with hash-style indexes (e.g., "0", "1")
    # instead of array format. This test ensures the controller handles both.
    assert_difference("Trigger.count") do
      post triggers_path, params: {
        trigger: {
          name: "Hash Indexed Trigger",
          status: "enabled",
          agent_root_name: "zimmer",
          prompt_template: "Test prompt: {{link}}",
          mcp_servers: [],
          trigger_conditions_attributes: {
            "0" => {
              condition_type: "slack",
              _destroy: "0",
              configuration: {
                channel_id: "C999888",
                channel_name: "test-hash",
                event_type: "new_message"
              }
            }
          }
        }
      }
    end

    trigger = Trigger.last
    assert_redirected_to trigger_path(trigger)
    condition = trigger.trigger_conditions.first
    assert_equal "slack", condition.condition_type
    assert_equal "C999888", condition.channel_id
  end

  test "should create schedule trigger with conditions" do
    assert_difference("Trigger.count") do
      post triggers_path, params: {
        trigger: {
          name: "New Schedule Trigger",
          status: "enabled",
          agent_root_name: "zimmer",
          prompt_template: "Run daily check at {{time}}",
          mcp_servers: [],
          trigger_conditions_attributes: [
            {
              condition_type: "schedule",
              configuration: {
                interval: "1",
                unit: "days",
                time: "09:00",
                timezone: "Eastern Time (US & Canada)"
              }
            }
          ]
        }
      }
    end

    trigger = Trigger.last
    assert_redirected_to trigger_path(trigger)
    condition = trigger.trigger_conditions.first
    assert_equal "schedule", condition.condition_type
    assert_equal "days", condition.schedule_unit
    assert_equal 1, condition.schedule_interval
    assert_equal "09:00", condition.schedule_time
  end

  test "should create ao_event trigger with conditions" do
    assert_difference("Trigger.count") do
      post triggers_path, params: {
        trigger: {
          name: "Zimmer Event Trigger",
          status: "enabled",
          agent_root_name: "zimmer",
          prompt_template: "Session needs input: {{event}}",
          mcp_servers: [],
          trigger_conditions_attributes: [
            {
              condition_type: "ao_event",
              configuration: {
                event_name: "session_needs_input"
              }
            }
          ]
        }
      }
    end

    trigger = Trigger.last
    assert_redirected_to trigger_path(trigger)
    condition = trigger.trigger_conditions.first
    assert_equal "ao_event", condition.condition_type
    assert_equal "session_needs_input", condition.ao_event_name
  end

  test "should create trigger with multiple conditions" do
    assert_difference("Trigger.count") do
      post triggers_path, params: {
        trigger: {
          name: "Multi Condition Trigger",
          status: "enabled",
          agent_root_name: "zimmer",
          prompt_template: "Triggered: {{event}} {{link}}",
          mcp_servers: [],
          trigger_conditions_attributes: [
            {
              condition_type: "slack",
              configuration: {
                channel_id: "C123456",
                channel_name: "test",
                event_type: "new_message"
              }
            },
            {
              condition_type: "schedule",
              configuration: {
                interval: "15",
                unit: "minutes"
              }
            }
          ]
        }
      }
    end

    trigger = Trigger.last
    assert_equal 2, trigger.trigger_conditions.count
  end

  test "should create trigger with reuse_session enabled" do
    assert_difference("Trigger.count") do
      post triggers_path, params: {
        trigger: {
          name: "Reuse Session Trigger",
          status: "enabled",
          agent_root_name: "zimmer",
          prompt_template: "Check at {{time}}",
          reuse_session: "1",
          mcp_servers: [],
          trigger_conditions_attributes: [
            {
              condition_type: "schedule",
              configuration: {
                interval: "5",
                unit: "minutes"
              }
            }
          ]
        }
      }
    end

    assert Trigger.last.reuse_session
  end

  test "should not create trigger with invalid params" do
    assert_no_difference("Trigger.count") do
      post triggers_path, params: {
        trigger: {
          name: "",
          agent_root_name: "zimmer",
          prompt_template: "Test",
          trigger_conditions_attributes: [
            {
              condition_type: "slack",
              configuration: {
                channel_id: "C123"
              }
            }
          ]
        }
      }
    end

    assert_response :unprocessable_entity
  end

  test "should show trigger" do
    get trigger_path(@trigger)
    assert_response :success
    assert_select "h1", @trigger.name
  end

  test "should show schedule trigger" do
    trigger = triggers(:enabled_schedule_trigger)
    get trigger_path(trigger)
    assert_response :success
    assert_select "h1", trigger.name
  end

  test "should show ao_event trigger" do
    trigger = triggers(:ao_event_trigger)
    get trigger_path(trigger)
    assert_response :success
    assert_select "h1", trigger.name
  end

  test "should get edit" do
    get edit_trigger_path(@trigger)
    assert_response :success
    assert_select "h1", "Edit Trigger"
  end

  test "should update trigger" do
    patch trigger_path(@trigger), params: {
      trigger: {
        name: "Updated Name"
      }
    }

    assert_redirected_to trigger_path(@trigger)
    @trigger.reload
    assert_equal "Updated Name", @trigger.name
  end

  test "should update trigger reuse_session" do
    patch trigger_path(@trigger), params: {
      trigger: {
        reuse_session: "1"
      }
    }

    assert_redirected_to trigger_path(@trigger)
    @trigger.reload
    assert @trigger.reuse_session
  end

  test "should not update trigger with invalid params" do
    patch trigger_path(@trigger), params: {
      trigger: {
        name: ""
      }
    }

    assert_response :unprocessable_entity
  end

  test "should destroy trigger" do
    assert_difference("Trigger.count", -1) do
      delete trigger_path(@trigger)
    end

    assert_redirected_to triggers_path
  end

  test "should toggle trigger from enabled to disabled" do
    assert @trigger.enabled?

    post toggle_trigger_path(@trigger)

    @trigger.reload
    assert @trigger.disabled?
    assert_redirected_to triggers_path
  end

  test "should toggle trigger from disabled to enabled" do
    disabled_trigger = triggers(:disabled_slack_trigger)
    assert disabled_trigger.disabled?

    post toggle_trigger_path(disabled_trigger)

    disabled_trigger.reload
    assert disabled_trigger.enabled?
    assert_redirected_to triggers_path
  end

  test "toggle returns turbo stream when requested" do
    post toggle_trigger_path(@trigger), headers: {
      "Accept" => "text/vnd.turbo-stream.html"
    }

    assert_response :success
    assert_match "turbo-stream", response.content_type
  end

  test "channels endpoint returns error when Slack not configured" do
    SlackService.stubs(:configured?).returns(false)
    get channels_triggers_path
    assert_response :service_unavailable
    json = JSON.parse(response.body)
    assert_includes json["error"], "Slack is not configured"
  end

  test "channels endpoint returns channels when Slack is configured" do
    SlackService.stubs(:configured?).returns(true)
    mock_channels = [
      OpenStruct.new(id: "C123", name: "general", is_private: false, num_members: 50),
      OpenStruct.new(id: "C456", name: "random", is_private: false, num_members: 30)
    ]
    SlackService.stubs(:list_channels).returns(mock_channels)

    get channels_triggers_path
    assert_response :success

    json = JSON.parse(response.body)
    assert_equal 2, json["channels"].length
    assert_equal "C123", json["channels"][0]["id"]
    assert_equal "general", json["channels"][0]["name"]
    assert_equal false, json["channels"][0]["is_private"]
    assert_equal 50, json["channels"][0]["num_members"]
  end

  test "channels endpoint handles Slack API errors" do
    SlackService.stubs(:configured?).returns(true)
    SlackService.stubs(:list_channels).raises(SlackService::ApiError.new("Rate limited"))

    get channels_triggers_path
    assert_response :service_unavailable

    json = JSON.parse(response.body)
    assert_includes json["error"], "Rate limited"
  end

  # Enqueue messages toggle tests
  test "should toggle enqueue_messages on when reuse_session is enabled" do
    @trigger.update!(reuse_session: true, enqueue_messages: false)

    post toggle_enqueue_messages_trigger_path(@trigger)

    @trigger.reload
    assert @trigger.enqueue_messages
    assert_redirected_to trigger_path(@trigger)
  end

  test "should toggle enqueue_messages off" do
    @trigger.update!(reuse_session: true, enqueue_messages: true)

    post toggle_enqueue_messages_trigger_path(@trigger)

    @trigger.reload
    assert_not @trigger.enqueue_messages
    assert_redirected_to trigger_path(@trigger)
  end

  test "should not toggle enqueue_messages when reuse_session is disabled" do
    @trigger.update!(reuse_session: false, enqueue_messages: false)

    post toggle_enqueue_messages_trigger_path(@trigger)

    @trigger.reload
    assert_not @trigger.enqueue_messages
    assert_redirected_to trigger_path(@trigger)
    assert_equal "Enqueue messages can only be enabled when re-use session is enabled.", flash[:alert]
  end

  test "toggle_enqueue_messages returns turbo stream when requested" do
    @trigger.update!(reuse_session: true, enqueue_messages: false)

    post toggle_enqueue_messages_trigger_path(@trigger), headers: {
      "Accept" => "text/vnd.turbo-stream.html"
    }

    assert_response :success
    assert_match "turbo-stream", response.content_type
  end

  # Resuscitate archived toggle tests
  test "should toggle resuscitate_archived on when reuse_session is enabled" do
    @trigger.update!(reuse_session: true, resuscitate_archived: false)

    post toggle_resuscitate_archived_trigger_path(@trigger)

    @trigger.reload
    assert @trigger.resuscitate_archived
    assert_redirected_to trigger_path(@trigger)
  end

  test "should toggle resuscitate_archived off" do
    @trigger.update!(reuse_session: true, resuscitate_archived: true)

    post toggle_resuscitate_archived_trigger_path(@trigger)

    @trigger.reload
    assert_not @trigger.resuscitate_archived
    assert_redirected_to trigger_path(@trigger)
  end

  test "should not toggle resuscitate_archived when reuse_session is disabled" do
    @trigger.update!(reuse_session: false, resuscitate_archived: false)

    post toggle_resuscitate_archived_trigger_path(@trigger)

    @trigger.reload
    assert_not @trigger.resuscitate_archived
    assert_redirected_to trigger_path(@trigger)
    assert_equal "Resuscitate archived can only be enabled when re-use session is enabled.", flash[:alert]
  end

  test "toggle_resuscitate_archived returns turbo stream when requested" do
    @trigger.update!(reuse_session: true, resuscitate_archived: false)

    post toggle_resuscitate_archived_trigger_path(@trigger), headers: {
      "Accept" => "text/vnd.turbo-stream.html"
    }

    assert_response :success
    assert_match "turbo-stream", response.content_type
  end

  # Catalog skills tests
  test "should create trigger with catalog_skills" do
    SkillsConfig.stubs(:exists?).returns(true)

    assert_difference("Trigger.count") do
      post triggers_path, params: {
        trigger: {
          name: "Trigger With Skills",
          status: "enabled",
          agent_root_name: "zimmer",
          prompt_template: "Do the thing: {{link}}",
          mcp_servers: [],
          catalog_skills: [ "commit", "review-pr" ],
          trigger_conditions_attributes: [
            {
              condition_type: "slack",
              configuration: {
                channel_id: "C123456",
                channel_name: "test-channel",
                event_type: "new_message"
              }
            }
          ]
        }
      }
    end

    trigger = Trigger.last
    assert_redirected_to trigger_path(trigger)
    assert_equal [ "commit", "review-pr" ], trigger.catalog_skills
  end

  test "should create trigger with empty catalog_skills" do
    assert_difference("Trigger.count") do
      post triggers_path, params: {
        trigger: {
          name: "Trigger Without Skills",
          status: "enabled",
          agent_root_name: "zimmer",
          prompt_template: "Do the thing: {{link}}",
          mcp_servers: [],
          catalog_skills: [],
          trigger_conditions_attributes: [
            {
              condition_type: "slack",
              configuration: {
                channel_id: "C123456",
                channel_name: "test-channel",
                event_type: "new_message"
              }
            }
          ]
        }
      }
    end

    trigger = Trigger.last
    assert_equal [], trigger.catalog_skills
  end

  test "show page displays catalog skills" do
    SkillsConfig.stubs(:exists?).returns(true)
    @trigger.update!(catalog_skills: [ "commit", "review-pr" ])

    get trigger_path(@trigger)
    assert_response :success
    assert_select "dt", text: "Skills"
    assert_select "dd span.bg-green-100", count: 2
  end

  # Form-based creation with sub-checkboxes
  test "should create trigger with enqueue_messages and resuscitate_archived via form" do
    assert_difference("Trigger.count") do
      post triggers_path, params: {
        trigger: {
          name: "Full Reuse Trigger",
          status: "enabled",
          agent_root_name: "zimmer",
          prompt_template: "Check at {{time}}",
          reuse_session: "1",
          enqueue_messages: "1",
          resuscitate_archived: "1",
          mcp_servers: [],
          trigger_conditions_attributes: [
            {
              condition_type: "schedule",
              configuration: {
                interval: "5",
                unit: "minutes"
              }
            }
          ]
        }
      }
    end

    trigger = Trigger.last
    assert trigger.reuse_session
    assert trigger.enqueue_messages
    assert trigger.resuscitate_archived
  end

  test "should clear enqueue_messages and resuscitate_archived when reuse_session is off via form" do
    assert_difference("Trigger.count") do
      post triggers_path, params: {
        trigger: {
          name: "No Reuse Trigger",
          status: "enabled",
          agent_root_name: "zimmer",
          prompt_template: "Check at {{time}}",
          reuse_session: "0",
          enqueue_messages: "1",
          resuscitate_archived: "1",
          mcp_servers: [],
          trigger_conditions_attributes: [
            {
              condition_type: "schedule",
              configuration: {
                interval: "5",
                unit: "minutes"
              }
            }
          ]
        }
      }
    end

    trigger = Trigger.last
    assert_not trigger.reuse_session
    assert_not trigger.enqueue_messages
    assert_not trigger.resuscitate_archived
  end

  # Manual invoke tests
  test "invoke creates session and redirects to it" do
    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo",
      default_branch: "main",
      subdirectory: nil
    )
    AgentRootsConfig.stubs(:find!).with(@trigger.agent_root_name).returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    assert_difference("Session.count", 1) do
      post invoke_trigger_path(@trigger)
    end

    session = Session.last
    assert_redirected_to session_path(session)
    assert_equal "Trigger \"#{@trigger.name}\" fired manually. Session created.", flash[:notice]
  end

  test "invoke interpolates provided variables into prompt" do
    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo",
      default_branch: "main",
      subdirectory: nil
    )
    AgentRootsConfig.stubs(:find!).with(@trigger.agent_root_name).returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    post invoke_trigger_path(@trigger), params: {
      link: "https://example.com/msg/1",
      channel: "eng-alerts"
    }

    session = Session.last
    assert_includes session.prompt, "https://example.com/msg/1"
    assert_includes session.prompt, "#eng-alerts"
  end

  test "invoke works without any variable params" do
    # Use the schedule trigger which has {{date}} and {{time}} (auto-populated)
    trigger = triggers(:enabled_schedule_trigger)
    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo",
      default_branch: "main",
      subdirectory: nil
    )
    AgentRootsConfig.stubs(:find!).with(trigger.agent_root_name).returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    assert_difference("Session.count", 1) do
      post invoke_trigger_path(trigger)
    end

    assert_redirected_to session_path(Session.last)
  end

  test "invoke redirects back to trigger on failure" do
    AgentRootsConfig.stubs(:find!).raises(AgentRootsConfig::AgentRootNotFoundError.new("Not found"))

    post invoke_trigger_path(@trigger)

    assert_redirected_to trigger_path(@trigger)
    assert_match "Failed to invoke trigger", flash[:alert]
  end

  test "show page renders Run Now button" do
    get trigger_path(@trigger)
    assert_response :success
    assert_select "button", text: /Run Now/
  end

  test "show page renders invoke panel with variable fields for slack trigger" do
    get trigger_path(@trigger)
    assert_response :success
    # The slack trigger fixture uses {{link}} and {{channel}} variables
    assert_select "[data-trigger-invoke-target='panel']"
    assert_select "label", text: "{{link}}"
    assert_select "label", text: "{{channel}}"
  end

  test "show page renders invoke panel without variable fields for schedule trigger" do
    trigger = triggers(:enabled_schedule_trigger)
    get trigger_path(trigger)
    assert_response :success
    assert_select "[data-trigger-invoke-target='panel']"
    # Schedule trigger uses {{date}} and {{time}} which are auto-populated
    assert_select "label", text: "{{link}}", count: 0
  end
end
