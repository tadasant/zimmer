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

  # The icon a row renders is asserted by name, not merely by presence: a
  # `system_event` trigger that quietly fell through to the gray fallback would
  # still show *an* icon, and that is the shape of the bug this pins.
  test "the list renders the system-event icon for a system_event trigger" do
    trigger = Trigger.create!(
      name: "Quota available — wake waiting sessions",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "Quota is back. {{event}}",
      trigger_conditions_attributes: [
        { condition_type: "system_event", configuration: { "event_name" => "quota_available" } }
      ]
    )

    get triggers_path
    assert_response :success
    assert_select "#trigger_#{trigger.id} svg[aria-label=?]", "System event", 1
  end

  # The account-reauth trigger is an `ao_event`, and the operator reads the two
  # kinds of platform trigger apart by their icons, so both are pinned.
  test "the list renders the Zimmer-event icon for an ao_event trigger" do
    trigger = triggers(:ao_event_trigger)

    get triggers_path
    assert_response :success
    assert_select "#trigger_#{trigger.id} svg[aria-label=?]", "Zimmer event", 1
  end

  test "should get new" do
    get new_trigger_path
    assert_response :success
    assert_select "h1", "New Trigger"
  end

  # The event has to be reachable from the form, or "add a trigger for it" means
  # editing the database by hand.
  test "new form offers both system events" do
    get new_trigger_path
    assert_response :success

    assert_select "select[name=?] option[value=?]", "trigger[trigger_conditions_attributes][0][configuration][event_name]", "quota_available"
    assert_select "select[name=?] option[value=?]", "trigger[trigger_conditions_attributes][0][configuration][event_name]", "no_sessions_in_progress"
  end

  # A card carries two selects named `configuration[event_name]` — one per event
  # vocabulary — so the hidden one has to be disabled or the browser submits the
  # key twice and the LAST one in the DOM wins, silently blanking the chosen
  # ao_event.
  test "only the event_name select for the condition's own type is submittable" do
    get new_trigger_path
    assert_response :success

    name = "trigger[trigger_conditions_attributes][0][configuration][event_name]"
    assert_select "select[name=?]", name, 2, "both event vocabularies render on a blank card"
    assert_select "select[name=?]:not([disabled])", name, 0,
      "a blank card has no condition type yet, so neither select may submit"
  end

  test "the event_name select of an edited condition's own type is enabled" do
    trigger = Trigger.create!(
      name: "Idle fleet groomer",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "Groom the backlog. {{event}}",
      trigger_conditions_attributes: [
        { condition_type: "system_event", configuration: { "event_name" => "no_sessions_in_progress" } }
      ]
    )

    get edit_trigger_path(trigger)
    assert_response :success

    name = "trigger[trigger_conditions_attributes][0][configuration][event_name]"
    assert_select "select[name=?]:not([disabled])", name, 1
    assert_select "select[name=?]:not([disabled]) option[selected][value=?]", name, "no_sessions_in_progress", 1
  end

  test "new form offers the DM and passive-listening event types, and not the deprecated one" do
    get new_trigger_path
    assert_response :success

    assert_select "select[name=?]", "trigger[trigger_conditions_attributes][0][configuration][event_type]" do
      assert_select "option[value=passive_listen_thread]", 1
      assert_select "option[value=passive_listen_channel]", 1
      assert_select "option[value=dm_message]", 1
      # The combined type still works for triggers that already name it, but a new
      # condition should never be created with it.
      assert_select "option[value=passive_listen]", 0
    end
  end

  test "the edit form keeps the deprecated event type selectable for a condition that has it" do
    trigger = triggers(:passive_listen_all_channels_trigger)
    get edit_trigger_path(trigger)
    assert_response :success

    assert_select "option[value=passive_listen][selected]", 1
  end

  # The form renders none of the poller's cursor keys, so without
  # TriggerCondition::SLACK_POLL_STATE_KEYS a plain "save" would submit a
  # configuration hash without them and reset a live condition to un-baselined.
  test "saving a Slack condition from the form preserves its poller cursors and allowlist" do
    trigger = triggers(:passive_listen_all_channels_trigger)
    condition = trigger.trigger_conditions.first
    condition.update!(configuration: condition.configuration.merge(
      "channel_timestamps" => { "C_GENERAL" => "1704067200.000000" },
      "thread_timestamps" => { "C_GENERAL:1704060000.000000" => "1704067100.000000" },
      "bot_activity_timestamps" => { "C_GENERAL" => "1704067000.000000" },
      "participating_threads" => [ "C_GENERAL:1704060000.000000" ],
      "allowed_user_ids" => %w[U222]
    ))

    patch trigger_path(trigger), params: {
      trigger: {
        name: trigger.name,
        trigger_conditions_attributes: [
          {
            id: condition.id,
            condition_type: "slack",
            configuration: { channel_id: "", channel_name: "", event_type: "passive_listen" }
          }
        ]
      }
    }

    condition.reload
    assert_equal "passive_listen", condition.event_type
    assert_equal({ "C_GENERAL" => "1704067200.000000" }, condition.channel_timestamps)
    assert_equal({ "C_GENERAL:1704060000.000000" => "1704067100.000000" }, condition.thread_timestamps)
    assert_equal({ "C_GENERAL" => "1704067000.000000" }, condition.bot_activity_timestamps)
    assert_equal [ "C_GENERAL:1704060000.000000" ], condition.participating_threads
    assert_equal %w[U222], condition.allowed_user_ids
  end

  test "the edit form renders the exclude-labels field for a github_issue condition" do
    condition = trigger_conditions(:github_issue_condition)
    condition.update!(configuration: condition.configuration.merge(
      "exclude_labels" => [ "hold issue work gate" ]
    ))

    get edit_trigger_path(condition.trigger)
    assert_response :success

    assert_select "textarea[name=?]",
                  "trigger[trigger_conditions_attributes][0][configuration][exclude_labels][]",
                  text: "hold issue work gate"
    # The block is only unhidden for github_issue — a github_label condition never sees it.
    assert_select "[data-trigger-form-target=githubIssueFields]:not(.hidden)", 1
  end

  test "the exclude-labels block is hidden for a github_label condition" do
    get edit_trigger_path(trigger_conditions(:github_label_condition).trigger)
    assert_response :success

    assert_select "[data-trigger-form-target=githubIssueFields].hidden", 1
  end

  test "saving a github_issue condition from the form stores the exclusion and keeps its cursor" do
    condition = trigger_conditions(:github_issue_condition)
    condition.update!(configuration: condition.configuration.merge(
      "last_issue_at" => "2026-07-12T09:00:00Z",
      "seen_issue_keys" => [ "tadasant/zimmer#42" ]
    ))

    patch trigger_path(condition.trigger), params: {
      trigger: {
        name: condition.trigger.name,
        trigger_conditions_attributes: [
          {
            id: condition.id,
            condition_type: "github_issue",
            # The textarea shape: one element carrying newlines.
            configuration: { repos: [ "tadasant/zimmer" ], exclude_labels: [ "hold issue work gate" ] }
          }
        ]
      }
    }

    condition.reload
    assert_equal [ "hold issue work gate" ], condition.github_exclude_labels
    assert_equal "2026-07-12T09:00:00Z", condition.github_last_issue_at
    assert_equal [ "tadasant/zimmer#42" ], condition.github_seen_issue_keys
  end

  test "an explicit empty allowlist still clears it" do
    condition = trigger_conditions(:passive_listen_all_channels_condition)
    condition.update!(configuration: condition.configuration.merge("allowed_user_ids" => %w[U222]))

    condition.update!(configuration: condition.configuration.merge("allowed_user_ids" => []))

    assert_empty condition.reload.configuration["allowed_user_ids"]
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

  test "the form saves skip_if_pending_session, and the detail page reports what it is doing" do
    post triggers_path, params: {
      trigger: {
        name: "Deduped Alerts Trigger",
        status: "enabled",
        agent_root_name: "zimmer",
        prompt_template: "New alert: {{link}}",
        skip_if_pending_session: "1",
        mcp_servers: [],
        trigger_conditions_attributes: [
          { condition_type: "slack", configuration: { channel_id: "C123456", channel_name: "alerts", event_type: "new_message" } }
        ]
      }
    }

    trigger = Trigger.find_by!(name: "Deduped Alerts Trigger")
    assert trigger.skip_if_pending_session

    get trigger_path(trigger)
    assert_response :success
    assert_select "#trigger-skip-if-pending-session", text: /Enabled/
    assert_select "body", text: /nothing pending/

    # A pending session it spawned: the page names the one it is deferring to.
    pending = sessions(:waiting)
    pending.update!(metadata: pending.metadata.merge("trigger_id" => trigger.id))
    get trigger_path(trigger)
    assert_select "body", text: /Skipping/

    # Unchecking the box turns it off (the form posts "0").
    patch trigger_path(trigger), params: { trigger: { skip_if_pending_session: "0" } }
    assert_not trigger.reload.skip_if_pending_session
  end

  test "the new trigger form renders the skip-while-pending checkbox" do
    get new_trigger_path
    assert_response :success
    assert_select "input[type=checkbox][name='trigger[skip_if_pending_session]']"
  end

  test "should create trigger with skip_if_pending_session, and toggle it off from the edit form" do
    post triggers_path, params: {
      trigger: {
        name: "Deduped Alerts Trigger",
        status: "enabled",
        agent_root_name: "zimmer",
        prompt_template: "New alert: {{link}}",
        skip_if_pending_session: "1",
        mcp_servers: [],
        trigger_conditions_attributes: [
          { condition_type: "slack", configuration: { channel_id: "C123456", channel_name: "alerts", event_type: "new_message" } }
        ]
      }
    }

    trigger = Trigger.find_by!(name: "Deduped Alerts Trigger")
    assert trigger.skip_if_pending_session

    patch trigger_path(trigger), params: { trigger: { skip_if_pending_session: "0" } }
    assert_not trigger.reload.skip_if_pending_session
  end

  test "the show page reports the dedup setting and names the session it is skipping for" do
    @trigger.update!(skip_if_pending_session: true)

    get trigger_path(@trigger)
    assert_response :success
    assert_select "#trigger-skip-if-pending-session", "Enabled"
    assert_select "body", { text: /nothing pending/, count: 1 }

    pending = sessions(:waiting)
    pending.update!(metadata: pending.metadata.merge("trigger_id" => @trigger.id))

    get trigger_path(@trigger)
    assert_response :success
    assert_select "body", { text: /is still pending/ }
    assert_select "a[href=?]", session_path(pending), text: "session ##{pending.id}"
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

  test "should create slack trigger with the dm_message event type and no channel" do
    assert_difference("Trigger.count") do
      post triggers_path, params: {
        trigger: {
          name: "DM Listener",
          status: "enabled",
          agent_root_name: "zimmer",
          prompt_template: "Someone DM'd you: {{text}}",
          mcp_servers: [],
          trigger_conditions_attributes: [
            {
              condition_type: "slack",
              configuration: {
                channel_id: "",
                channel_name: "",
                event_type: "dm_message"
              }
            }
          ]
        }
      }
    end

    trigger = Trigger.last
    assert_redirected_to trigger_path(trigger)
    condition = trigger.trigger_conditions.first
    assert_equal "dm_message", condition.event_type
    assert_equal "", condition.channel_id
  end

  test "should create slack trigger with a passive-listening event type and no channel" do
    assert_difference("Trigger.count") do
      post triggers_path, params: {
        trigger: {
          name: "Passive Listener",
          status: "enabled",
          agent_root_name: "zimmer",
          prompt_template: "Something landed in a thread you are in: {{text}}",
          mcp_servers: [],
          trigger_conditions_attributes: [
            {
              condition_type: "slack",
              configuration: {
                channel_id: "",
                channel_name: "",
                event_type: "passive_listen_thread"
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
    assert_equal "passive_listen_thread", condition.event_type
    assert condition.passive_threads?
    assert_not condition.passive_channel?
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

  # The badge is asserted by its text: a `system_event` condition that fell
  # through to the fallback would still render *a* pill, carrying the raw enum
  # value, which is the shape of the bug this pins.
  test "show badges a system_event condition with words rather than its raw enum value" do
    trigger = Trigger.create!(
      name: "Quota available — wake waiting sessions",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "Quota is back. {{event}}",
      trigger_conditions_attributes: [
        { condition_type: "system_event", configuration: { "event_name" => "quota_available" } }
      ]
    )

    get trigger_path(trigger)
    assert_response :success
    assert_select "span", text: "System Event", count: 1
    assert_select "span", text: "Quota available again", count: 1
    assert_select "span", text: "system_event", count: 0
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

  # === Failed triggers stay visible and re-armable (issue #76) ===

  test "index shows a failed trigger with its error rather than hiding or dropping it" do
    @trigger.mark_failed(StandardError.new("Agent root 'gone' not found in catalog"))

    get triggers_path

    assert_response :success
    assert_match @trigger.name, response.body, "the failed trigger is still listed"
    assert_match "Failed", response.body
    assert_match "Agent root &#39;gone&#39; not found in catalog", response.body
    assert_match "Re-arm", response.body
  end

  test "show explains the failure and offers a re-arm" do
    @trigger.mark_failed(StandardError.new("Agent root 'gone' not found in catalog"))

    get trigger_path(@trigger)

    assert_response :success
    assert_match "This trigger failed to fire", response.body
    assert_match "Agent root &#39;gone&#39; not found in catalog", response.body
    assert_match "Re-arm", response.body
  end

  test "toggling a failed trigger re-arms it" do
    @trigger.mark_failed(StandardError.new("boom"))

    post toggle_trigger_path(@trigger)

    @trigger.reload
    assert @trigger.enabled?
    assert_nil @trigger.failed_at
    assert_nil @trigger.last_error
    assert_redirected_to triggers_path
    assert_equal "Trigger re-armed.", flash[:notice]
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

  test "the form's scheduling class is permitted, and blank means derive" do
    trigger = triggers(:enabled_schedule_trigger)

    patch trigger_path(trigger), params: { trigger: { name: trigger.name, scheduling_class: "priority" } }
    assert_equal SessionGenesis::PRIORITY, trigger.reload.scheduling_class

    patch trigger_path(trigger), params: { trigger: { name: trigger.name, scheduling_class: "" } }
    assert_nil trigger.reload.scheduling_class, "the \"Default\" option submits blank, not a class named empty"
  end

  test "the form's precedence is permitted, and blank predefines nothing" do
    trigger = triggers(:enabled_schedule_trigger)

    patch trigger_path(trigger), params: { trigger: { name: trigger.name, precedence: "750" } }
    assert_equal 750, trigger.reload.precedence

    patch trigger_path(trigger), params: { trigger: { name: trigger.name, precedence: "" } }
    assert_nil trigger.reload.precedence, "an empty field predefines nothing, rather than a rank of zero"
  end

  test "the trigger page shows a predefined precedence" do
    trigger = triggers(:enabled_schedule_trigger)

    get trigger_path(trigger)
    assert_response :success
    assert_select "#trigger-precedence", text: /none predefined/

    trigger.update!(precedence: 4242)
    get trigger_path(trigger)
    assert_select "#trigger-precedence", text: /4242/
  end

  test "the trigger page shows the effective class and where it came from" do
    trigger = triggers(:enabled_schedule_trigger)

    get trigger_path(trigger)
    assert_response :success
    assert_select "#trigger-scheduling-class", text: /spot/
    assert_match(/default for its conditions/, response.body)

    trigger.update!(scheduling_class: SessionGenesis::PRIORITY)
    get trigger_path(trigger)
    assert_select "#trigger-scheduling-class", text: /priority/
    assert_match(/set on this trigger/, response.body)
  end
end
