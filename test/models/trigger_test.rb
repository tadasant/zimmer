# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"
require "ostruct"

class TriggerTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @trigger = triggers(:enabled_slack_trigger)
    ServersConfig.stubs(:exists?).returns(true)
    SkillsConfig.stubs(:exists?).returns(true)
    HooksConfig.stubs(:exists?).returns(true)
    PluginsConfig.stubs(:exists?).returns(true)
    AgentRootsConfig.stubs(:exists?).returns(true)
  end

  # Validations
  test "valid trigger is valid" do
    assert @trigger.valid?
  end

  test "requires name" do
    @trigger.name = nil
    assert_not @trigger.valid?
    assert_includes @trigger.errors[:name], "can't be blank"
  end

  test "requires agent_root_name" do
    @trigger.agent_root_name = nil
    assert_not @trigger.valid?
    assert_includes @trigger.errors[:agent_root_name], "can't be blank"
  end

  test "requires prompt_template" do
    @trigger.prompt_template = nil
    assert_not @trigger.valid?
    assert_includes @trigger.errors[:prompt_template], "can't be blank"
  end

  test "requires status" do
    @trigger.status = nil
    assert_not @trigger.valid?
    assert_includes @trigger.errors[:status], "can't be blank"
  end

  test "status must be valid" do
    @trigger.status = "invalid"
    assert_not @trigger.valid?
    assert_includes @trigger.errors[:status], "is not included in the list"
  end

  test "requires at least one trigger condition" do
    trigger = Trigger.new(
      name: "Test",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "Test"
    )
    assert_not trigger.valid?
    assert_includes trigger.errors[:trigger_conditions], "must have at least one condition"
  end

  # Associations
  test "has many trigger_conditions" do
    assert @trigger.respond_to?(:trigger_conditions)
    assert @trigger.trigger_conditions.count >= 1
  end

  test "destroying trigger destroys conditions" do
    condition_count = @trigger.trigger_conditions.count
    assert condition_count > 0

    assert_difference("TriggerCondition.count", -condition_count) do
      @trigger.destroy
    end
  end

  test "accepts nested attributes for trigger_conditions" do
    trigger = Trigger.new(
      name: "Nested Test",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "Test",
      trigger_conditions_attributes: [
        { condition_type: "slack", configuration: { "channel_id" => "C123", "channel_name" => "test" } }
      ]
    )
    assert trigger.valid?, "Expected trigger with nested conditions to be valid, got: #{trigger.errors.full_messages}"
  end

  test "multi_condition_trigger has multiple conditions" do
    trigger = triggers(:multi_condition_trigger)
    assert trigger.trigger_conditions.count >= 2
  end

  # Scopes
  test "enabled scope returns only enabled triggers" do
    enabled_triggers = Trigger.enabled
    assert enabled_triggers.all?(&:enabled?)
    assert_not enabled_triggers.any?(&:disabled?)
  end

  test "disabled scope returns only disabled triggers" do
    disabled_triggers = Trigger.disabled
    assert disabled_triggers.all?(&:disabled?)
    assert_not disabled_triggers.any?(&:enabled?)
  end

  test "with_slack_conditions scope returns triggers that have slack conditions" do
    triggers_list = Trigger.with_slack_conditions
    triggers_list.each do |trigger|
      assert trigger.trigger_conditions.any? { |c| c.condition_type == "slack" }
    end
  end

  test "with_schedule_conditions scope returns triggers that have schedule conditions" do
    triggers_list = Trigger.with_schedule_conditions
    triggers_list.each do |trigger|
      assert trigger.trigger_conditions.any? { |c| c.condition_type == "schedule" }
    end
  end

  test "with_ao_event_conditions scope returns triggers that have ao_event conditions" do
    triggers_list = Trigger.with_ao_event_conditions
    triggers_list.each do |trigger|
      assert trigger.trigger_conditions.any? { |c| c.condition_type == "ao_event" }
    end
  end

  # Status methods
  test "enabled? returns true when status is enabled" do
    @trigger.status = "enabled"
    assert @trigger.enabled?
    assert_not @trigger.disabled?
  end

  test "disabled? returns true when status is disabled" do
    @trigger.status = "disabled"
    assert @trigger.disabled?
    assert_not @trigger.enabled?
  end

  test "enable! changes status to enabled" do
    @trigger.status = "disabled"
    @trigger.enable!
    assert @trigger.enabled?
  end

  test "disable! changes status to disabled" do
    @trigger.status = "enabled"
    @trigger.disable!
    assert @trigger.disabled?
  end

  test "toggle! toggles between enabled and disabled" do
    @trigger.status = "enabled"
    @trigger.toggle!
    assert @trigger.disabled?

    @trigger.toggle!
    assert @trigger.enabled?
  end

  # condition_types and conditions_summary
  test "condition_types returns unique condition types" do
    types = @trigger.condition_types
    assert_includes types, "slack"
  end

  test "conditions_summary returns human-readable summary" do
    summary = @trigger.conditions_summary
    assert summary.present?
  end

  test "multi_condition_trigger has multiple condition types" do
    trigger = triggers(:multi_condition_trigger)
    types = trigger.condition_types
    assert types.length >= 2
  end

  # prompt_variables
  test "prompt_variables returns user-input variables used in template" do
    @trigger.prompt_template = "Check {{link}} from {{author}} in {{channel}}"
    assert_equal %w[link author channel], @trigger.prompt_variables
  end

  test "prompt_variables excludes auto-populated variables" do
    @trigger.prompt_template = "Status at {{time}} on {{date}}"
    assert_equal [], @trigger.prompt_variables
  end

  test "prompt_variables returns all user-input variables when all used" do
    @trigger.prompt_template = "{{link}} {{text}} {{author}} {{channel}} {{event}}"
    assert_equal %w[link text author channel event], @trigger.prompt_variables
  end

  test "prompt_variables returns empty for template with no variables" do
    @trigger.prompt_template = "Run the daily check"
    assert_equal [], @trigger.prompt_variables
  end

  # Prompt interpolation
  test "interpolate_prompt replaces link variable" do
    result = @trigger.interpolate_prompt(link: "https://slack.com/msg/123")
    assert_includes result, "https://slack.com/msg/123"
  end

  test "interpolate_prompt replaces text variable" do
    @trigger.prompt_template = "Message: {{text}}"
    result = @trigger.interpolate_prompt(text: "Hello world")
    assert_equal "Message: Hello world", result
  end

  test "interpolate_prompt replaces author variable" do
    @trigger.prompt_template = "From {{author}}"
    result = @trigger.interpolate_prompt(author: "John Doe")
    assert_equal "From John Doe", result
  end

  test "interpolate_prompt replaces channel variable" do
    result = @trigger.interpolate_prompt(channel: "eng-ci")
    assert_includes result, "#eng-ci"
  end

  test "interpolate_prompt handles nil values" do
    @trigger.prompt_template = "{{link}} - {{text}}"
    result = @trigger.interpolate_prompt(link: nil, text: nil)
    assert_equal " - ", result
  end

  test "interpolate_prompt replaces time variable" do
    @trigger.prompt_template = "Current time: {{time}}"
    result = @trigger.interpolate_prompt
    assert_match(/\d{2}:\d{2}/, result)
  end

  test "interpolate_prompt replaces date variable" do
    @trigger.prompt_template = "Current date: {{date}}"
    result = @trigger.interpolate_prompt
    assert_match(/\d{4}-\d{2}-\d{2}/, result)
  end

  test "interpolate_prompt replaces event variable" do
    @trigger.prompt_template = "Event: {{event}}"
    result = @trigger.interpolate_prompt(event: "Session #5 needs input")
    assert_equal "Event: Session #5 needs input", result
  end

  # create_session!
  test "create_session! creates a session and enqueues job" do
    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo",
      default_branch: "main",
      subdirectory: nil
    )
    AgentRootsConfig.stubs(:find!).with(@trigger.agent_root_name).returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    original_count = @trigger.sessions_created_count

    assert_difference("Session.count", 1) do
      session = @trigger.create_session!(prompt: "Test prompt")
      assert_equal "Test prompt", session.prompt
      assert_equal "claude_code", session.agent_runtime
      assert_equal mock_agent_root.url, session.git_root
      assert_equal @trigger.mcp_servers, session.mcp_servers
      assert_equal @trigger.id.to_s, session.metadata["trigger_id"].to_s
      assert_equal @trigger.name, session.metadata["trigger_name"]
    end

    @trigger.reload
    assert_equal original_count + 1, @trigger.sessions_created_count
    assert_not_nil @trigger.last_triggered_at
    assert_not_nil @trigger.last_session_id
  end

  test "create_session! enqueues SessionTitleJob" do
    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo",
      default_branch: "main",
      subdirectory: nil
    )
    AgentRootsConfig.stubs(:find!).with(@trigger.agent_root_name).returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    assert_enqueued_with(job: SessionTitleJob) do
      @trigger.create_session!(prompt: "Test prompt for title generation")
    end
  end

  test "create_session! raises error when agent root not found and no successor" do
    AgentRootsConfig.stubs(:exists?).with(@trigger.agent_root_name).returns(false)

    assert_raises(AgentRootsConfig::AgentRootNotFoundError) do
      @trigger.create_session!(prompt: "Test")
    end
  end

  # Session reuse tests
  test "create_session! reuses session when reuse_session is true and session is needs_input" do
    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo",
      default_branch: "main",
      subdirectory: nil
    )
    AgentRootsConfig.stubs(:find!).with(@trigger.agent_root_name).returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)
    AgentSessionJob.stubs(:enqueue_with_prompt)

    # First, create a session
    session = @trigger.create_session!(prompt: "Initial prompt")

    # Set up for reuse
    @trigger.update!(reuse_session: true, last_session_id: session.id)

    # Simulate session being in needs_input state
    session.update_column(:status, Session.statuses[:needs_input])

    # The next invocation should reuse the session
    original_session_count = Session.count
    original_created_count = @trigger.reload.sessions_created_count
    reused = @trigger.create_session!(prompt: "Follow-up prompt")

    assert_equal session.id, reused.id
    assert_equal original_session_count, Session.count
    # sessions_created_count should NOT be incremented when reusing a session
    assert_equal original_created_count, @trigger.reload.sessions_created_count
  end

  test "create_session! transitions needs_input session to running before enqueuing follow-up" do
    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo",
      default_branch: "main",
      subdirectory: nil
    )
    AgentRootsConfig.stubs(:find!).with(@trigger.agent_root_name).returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)
    AgentSessionJob.stubs(:enqueue_with_prompt)

    # Create a session and set up for reuse
    session = @trigger.create_session!(prompt: "Initial prompt")
    @trigger.update!(reuse_session: true, last_session_id: session.id)

    # Simulate session being in needs_input state
    session.update_column(:status, Session.statuses[:needs_input])

    # Reuse the session
    @trigger.create_session!(prompt: "Follow-up prompt")

    # Session should have been transitioned to running (like the controller does)
    session.reload
    assert session.running?, "Expected session to be in running state after follow-up, but was #{session.status}"
  end

  test "create_session! enqueues follow-up prompt when reusing needs_input session" do
    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo",
      default_branch: "main",
      subdirectory: nil
    )
    AgentRootsConfig.stubs(:find!).with(@trigger.agent_root_name).returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    # Create a session and set up for reuse
    session = @trigger.create_session!(prompt: "Initial prompt")
    @trigger.update!(reuse_session: true, last_session_id: session.id)

    # Simulate session being in needs_input state
    session.update_column(:status, Session.statuses[:needs_input])

    # Verify enqueue_with_prompt is called with the correct session and prompt
    AgentSessionJob.expects(:enqueue_with_prompt).with(session.id, "Follow-up prompt").once

    @trigger.create_session!(prompt: "Follow-up prompt")
  end

  test "create_session! enqueues message when reusing running session with enqueue_messages enabled" do
    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo",
      default_branch: "main",
      subdirectory: nil
    )
    AgentRootsConfig.stubs(:find!).with(@trigger.agent_root_name).returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    # Create a session and set up for reuse with enqueue_messages enabled
    session = @trigger.create_session!(prompt: "Initial prompt")
    @trigger.update!(reuse_session: true, enqueue_messages: true, last_session_id: session.id)

    # Simulate session being in running state
    session.update_column(:status, Session.statuses[:running])

    # Reuse should create an enqueued message instead of enqueuing a job
    assert_difference("session.enqueued_messages.count", 1) do
      reused = @trigger.create_session!(prompt: "Queued prompt")
      assert_equal session.id, reused.id
    end

    enqueued = session.enqueued_messages.last
    assert_equal "Queued prompt", enqueued.content
    assert_equal "pending", enqueued.status
  end

  test "create_session! skips enqueue when reusing running session with enqueue_messages disabled" do
    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo",
      default_branch: "main",
      subdirectory: nil
    )
    AgentRootsConfig.stubs(:find!).with(@trigger.agent_root_name).returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    # Create a session and set up for reuse WITHOUT enqueue_messages
    session = @trigger.create_session!(prompt: "Initial prompt")
    @trigger.update!(reuse_session: true, enqueue_messages: false, last_session_id: session.id)

    # Simulate session being in running state
    session.update_column(:status, Session.statuses[:running])

    # Should NOT create an enqueued message - just skip and return the session
    assert_no_difference("session.enqueued_messages.count") do
      reused = @trigger.create_session!(prompt: "Skipped prompt")
      assert_equal session.id, reused.id
    end

    # last_triggered_at should still be updated
    assert_not_nil @trigger.reload.last_triggered_at
  end

  test "create_session! skips enqueue when running session already has pending messages" do
    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo",
      default_branch: "main",
      subdirectory: nil
    )
    AgentRootsConfig.stubs(:find!).with(@trigger.agent_root_name).returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    # Create a session and set up for reuse with enqueue_messages enabled
    session = @trigger.create_session!(prompt: "Initial prompt")
    @trigger.update!(reuse_session: true, enqueue_messages: true, last_session_id: session.id)

    # Simulate session being in running state
    session.update_column(:status, Session.statuses[:running])

    # Add an existing pending enqueued message
    session.enqueued_messages.create!(content: "Already queued", position: 1, status: "pending")

    # Should NOT create another enqueued message since one is already pending
    assert_no_difference("session.enqueued_messages.count") do
      reused = @trigger.create_session!(prompt: "Should be skipped")
      assert_equal session.id, reused.id
    end

    # last_triggered_at should still be updated
    assert_not_nil @trigger.reload.last_triggered_at
  end

  test "create_session! creates new session when reuse_session is true but no previous session" do
    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo",
      default_branch: "main",
      subdirectory: nil
    )
    AgentRootsConfig.stubs(:find!).with(@trigger.agent_root_name).returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    @trigger.update!(reuse_session: true)

    assert_difference("Session.count", 1) do
      @trigger.create_session!(prompt: "New prompt")
    end
  end

  test "create_session! creates new session when reuse_session is false" do
    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo",
      default_branch: "main",
      subdirectory: nil
    )
    AgentRootsConfig.stubs(:find!).with(@trigger.agent_root_name).returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    @trigger.update!(reuse_session: false)

    assert_difference("Session.count", 1) do
      @trigger.create_session!(prompt: "Test")
    end

    assert_difference("Session.count", 1) do
      @trigger.create_session!(prompt: "Test again")
    end
  end

  test "create_session! creates new session when previous session is archived" do
    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo",
      default_branch: "main",
      subdirectory: nil
    )
    AgentRootsConfig.stubs(:find!).with(@trigger.agent_root_name).returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    # Create initial session
    session = @trigger.create_session!(prompt: "Initial")
    @trigger.update!(reuse_session: true, last_session_id: session.id)

    # Archive the session
    session.update_column(:status, Session.statuses[:archived])

    # Should create a new session since archived is not reusable
    assert_difference("Session.count", 1) do
      new_session = @trigger.create_session!(prompt: "New prompt")
      assert_not_equal session.id, new_session.id
    end
  end

  test "create_session! does not reuse session when paused_by user" do
    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo",
      default_branch: "main",
      subdirectory: nil
    )
    AgentRootsConfig.stubs(:find!).with(@trigger.agent_root_name).returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    # Create initial session
    session = @trigger.create_session!(prompt: "Initial")
    @trigger.update!(reuse_session: true, last_session_id: session.id)

    # Simulate user pausing the session (non-autonomous)
    session.update_column(:status, Session.statuses[:needs_input])
    session.update!(metadata: (session.metadata || {}).merge("paused_by" => "user"))

    # Should create a new session since user-paused sessions are not reusable
    assert_difference("Session.count", 1) do
      new_session = @trigger.create_session!(prompt: "New prompt")
      assert_not_equal session.id, new_session.id
    end
  end

  test "create_session! syncs MCP servers when reusing session" do
    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo",
      default_branch: "main",
      subdirectory: nil
    )
    AgentRootsConfig.stubs(:find!).with(@trigger.agent_root_name).returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)
    AgentSessionJob.stubs(:enqueue_with_prompt)

    # Create initial session with original MCP servers
    @trigger.update!(mcp_servers: [ "server-a", "server-b" ])
    session = @trigger.create_session!(prompt: "Initial")
    assert_equal [ "server-a", "server-b" ], session.mcp_servers

    # Set up for reuse
    @trigger.update!(reuse_session: true, last_session_id: session.id)

    # Change trigger's MCP servers
    @trigger.update!(mcp_servers: [ "server-b", "server-c" ])

    # Simulate session being in needs_input state
    session.update_column(:status, Session.statuses[:needs_input])

    # Reuse should sync MCP servers
    reused = @trigger.create_session!(prompt: "Follow-up")
    assert_equal session.id, reused.id
    assert_equal [ "server-b", "server-c" ], reused.reload.mcp_servers
  end

  test "create_session! resets SIGTERM retry metadata when reusing needs_input session" do
    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo",
      default_branch: "main",
      subdirectory: nil
    )
    AgentRootsConfig.stubs(:find!).with(@trigger.agent_root_name).returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)
    AgentSessionJob.stubs(:enqueue_with_prompt)

    # Create a session and set up for reuse
    session = @trigger.create_session!(prompt: "Initial prompt")
    @trigger.update!(reuse_session: true, last_session_id: session.id)

    # Simulate session in needs_input state with SIGTERM retry metadata
    session.update_column(:status, Session.statuses[:needs_input])
    session.update!(metadata: {
      "sigterm_retry_count" => 2,
      "sigterm_retry_timestamps" => [ "2026-02-20T09:00:00Z" ],
      "last_sigterm_at" => "2026-02-20T09:00:00Z",
      "trigger_id" => @trigger.id
    })

    @trigger.create_session!(prompt: "Follow-up prompt")

    session.reload
    assert_nil session.metadata["sigterm_retry_count"]
    assert_nil session.metadata["sigterm_retry_timestamps"]
    assert_nil session.metadata["last_sigterm_at"]
    # Non-SIGTERM metadata should be preserved
    assert_equal @trigger.id, session.metadata["trigger_id"]
  end

  test "create_session! stores pending_follow_up_prompt in metadata when reusing needs_input session" do
    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo",
      default_branch: "main",
      subdirectory: nil
    )
    AgentRootsConfig.stubs(:find!).with(@trigger.agent_root_name).returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)
    AgentSessionJob.stubs(:enqueue_with_prompt)

    # Create a session and set up for reuse
    session = @trigger.create_session!(prompt: "Initial prompt")
    @trigger.update!(reuse_session: true, last_session_id: session.id)

    # Simulate session in needs_input state
    session.update_column(:status, Session.statuses[:needs_input])

    @trigger.create_session!(prompt: "Follow-up prompt")

    session.reload
    assert_equal "Follow-up prompt", session.metadata["pending_follow_up_prompt"]
  end

  # Catalog skills validations
  test "catalog_skills defaults to empty array" do
    trigger = Trigger.new(
      name: "Test",
      agent_root_name: "zimmer",
      prompt_template: "Test"
    )
    assert_equal [], trigger.catalog_skills
  end

  test "catalog_skills must be an array" do
    @trigger.catalog_skills = "not_an_array"
    assert_not @trigger.valid?
    assert_includes @trigger.errors[:catalog_skills], "must be an array"
  end

  test "catalog_skills validates skill names exist in catalog" do
    SkillsConfig.stubs(:exists?).with("valid-skill").returns(true)
    SkillsConfig.stubs(:exists?).with("nonexistent-skill").returns(false)
    @trigger.catalog_skills = [ "valid-skill", "nonexistent-skill" ]
    assert_not @trigger.valid?
    assert @trigger.errors[:catalog_skills].any? { |e| e.include?("nonexistent-skill") }
  end

  test "catalog_skills accepts valid skill names" do
    SkillsConfig.stubs(:exists?).returns(true)
    @trigger.catalog_skills = [ "some-skill" ]
    @trigger.valid?
    assert_empty @trigger.errors[:catalog_skills]
  end

  test "catalog_skills accepts empty array" do
    @trigger.catalog_skills = []
    @trigger.valid?
    assert_empty @trigger.errors[:catalog_skills]
  end

  test "create_session! passes catalog_skills to session" do
    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo",
      default_branch: "main",
      subdirectory: nil
    )
    AgentRootsConfig.stubs(:find!).with(@trigger.agent_root_name).returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)
    SkillsConfig.stubs(:exists?).returns(true)

    @trigger.update!(catalog_skills: [ "commit", "review-pr" ])

    session = @trigger.create_session!(prompt: "Test prompt")
    assert_equal [ "commit", "review-pr" ], session.catalog_skills
  end

  test "create_session! falls back to agent root default skills when trigger catalog_skills is empty" do
    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo",
      default_branch: "main",
      subdirectory: nil,
      default_skills: [ "zimmer-start-dev-server", "zimmer-run-tests" ]
    )
    AgentRootsConfig.stubs(:find!).with(@trigger.agent_root_name).returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    @trigger.update!(catalog_skills: [])

    session = @trigger.create_session!(prompt: "Test prompt")
    # A trigger's catalog columns default to [] (the creation flow does not resolve
    # the agent root's defaults into them), so an empty value means "not configured"
    # and must fall back to the agent root's defaults — matching the REST create path
    # (Api::V1::SessionsController#resolve_agent_root_defaults!, which uses .blank?).
    # Passing [] straight through would silently drop the root defaults.
    assert_equal [ "zimmer-start-dev-server", "zimmer-run-tests" ], session.catalog_skills
  end

  test "create_session! syncs catalog_skills when reusing session" do
    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo",
      default_branch: "main",
      subdirectory: nil
    )
    AgentRootsConfig.stubs(:find!).with(@trigger.agent_root_name).returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)
    AgentSessionJob.stubs(:enqueue_with_prompt)
    SkillsConfig.stubs(:exists?).returns(true)

    # Create initial session with original catalog skills
    @trigger.update!(catalog_skills: [ "skill-a" ])
    session = @trigger.create_session!(prompt: "Initial")
    assert_equal [ "skill-a" ], session.catalog_skills

    # Set up for reuse
    @trigger.update!(reuse_session: true, last_session_id: session.id)

    # Change trigger's catalog skills
    @trigger.update!(catalog_skills: [ "skill-b", "skill-c" ])

    # Simulate session being in needs_input state
    session.update_column(:status, Session.statuses[:needs_input])

    # Reuse should sync catalog skills
    reused = @trigger.create_session!(prompt: "Follow-up")
    assert_equal session.id, reused.id
    assert_equal [ "skill-b", "skill-c" ], reused.reload.catalog_skills
  end

  # catalog_hooks tests
  test "catalog_hooks defaults to empty array" do
    trigger = Trigger.new(
      name: "Test",
      agent_root_name: "zimmer",
      prompt_template: "Test"
    )
    assert_equal [], trigger.catalog_hooks
  end

  test "catalog_hooks must be an array" do
    @trigger.catalog_hooks = "not_an_array"
    assert_not @trigger.valid?
    assert_includes @trigger.errors[:catalog_hooks], "must be an array"
  end

  test "catalog_hooks validates hook names exist in catalog" do
    HooksConfig.stubs(:exists?).with("valid-hook").returns(true)
    HooksConfig.stubs(:exists?).with("nonexistent-hook").returns(false)
    @trigger.catalog_hooks = [ "valid-hook", "nonexistent-hook" ]
    assert_not @trigger.valid?
    assert @trigger.errors[:catalog_hooks].any? { |e| e.include?("nonexistent-hook") }
  end

  test "catalog_hooks accepts valid hook names" do
    HooksConfig.stubs(:exists?).returns(true)
    @trigger.catalog_hooks = [ "some-hook" ]
    @trigger.valid?
    assert_empty @trigger.errors[:catalog_hooks]
  end

  test "catalog_hooks accepts empty array" do
    @trigger.catalog_hooks = []
    @trigger.valid?
    assert_empty @trigger.errors[:catalog_hooks]
  end

  test "create_session! passes catalog_hooks to session" do
    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo",
      default_branch: "main",
      subdirectory: nil
    )
    AgentRootsConfig.stubs(:find!).with(@trigger.agent_root_name).returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)
    HooksConfig.stubs(:exists?).returns(true)

    @trigger.update!(catalog_hooks: [ "git-push-ci-reminder" ])

    session = @trigger.create_session!(prompt: "Test prompt")
    assert_equal [ "git-push-ci-reminder" ], session.catalog_hooks
  end

  test "create_session! syncs catalog_hooks when reusing session" do
    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo",
      default_branch: "main",
      subdirectory: nil
    )
    AgentRootsConfig.stubs(:find!).with(@trigger.agent_root_name).returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)
    AgentSessionJob.stubs(:enqueue_with_prompt)
    HooksConfig.stubs(:exists?).returns(true)

    # Create initial session with original catalog hooks
    @trigger.update!(catalog_hooks: [ "hook-a" ])
    session = @trigger.create_session!(prompt: "Initial")
    assert_equal [ "hook-a" ], session.catalog_hooks

    # Set up for reuse
    @trigger.update!(reuse_session: true, last_session_id: session.id)

    # Change trigger's catalog hooks
    @trigger.update!(catalog_hooks: [ "hook-b" ])

    # Simulate session being in needs_input state
    session.update_column(:status, Session.statuses[:needs_input])

    # Reuse should sync catalog hooks
    reused = @trigger.create_session!(prompt: "Follow-up")
    assert_equal session.id, reused.id
    assert_equal [ "hook-b" ], reused.reload.catalog_hooks
  end

  # catalog_plugins tests
  test "catalog_plugins defaults to empty array" do
    trigger = Trigger.new(
      name: "Test",
      agent_root_name: "zimmer",
      prompt_template: "Test"
    )
    assert_equal [], trigger.catalog_plugins
  end

  test "catalog_plugins must be an array" do
    @trigger.catalog_plugins = "not_an_array"
    assert_not @trigger.valid?
    assert_includes @trigger.errors[:catalog_plugins], "must be an array"
  end

  test "catalog_plugins validates plugin ids exist in catalog" do
    PluginsConfig.stubs(:exists?).with("valid-plugin").returns(true)
    PluginsConfig.stubs(:exists?).with("nonexistent-plugin").returns(false)
    @trigger.catalog_plugins = [ "valid-plugin", "nonexistent-plugin" ]
    assert_not @trigger.valid?
    assert @trigger.errors[:catalog_plugins].any? { |e| e.include?("nonexistent-plugin") }
  end

  test "catalog_plugins accepts valid plugin ids" do
    PluginsConfig.stubs(:exists?).returns(true)
    @trigger.catalog_plugins = [ "some-plugin" ]
    assert @trigger.valid?
    assert_empty @trigger.errors[:catalog_plugins]
  end

  test "catalog_plugins accepts empty array" do
    @trigger.catalog_plugins = []
    assert @trigger.valid?
    assert_empty @trigger.errors[:catalog_plugins]
  end

  test "create_session! passes catalog_plugins to session" do
    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo",
      default_branch: "main",
      subdirectory: nil
    )
    AgentRootsConfig.stubs(:find!).with(@trigger.agent_root_name).returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)
    PluginsConfig.stubs(:exists?).returns(true)

    @trigger.update!(catalog_plugins: [ "ci-workflow" ])
    session = @trigger.create_session!(prompt: "Test with plugins")
    assert_equal [ "ci-workflow" ], session.catalog_plugins
  end

  # Enqueue messages validation tests
  test "enqueue_messages defaults to false" do
    trigger = Trigger.new(
      name: "Test",
      agent_root_name: "zimmer",
      prompt_template: "Test"
    )
    assert_equal false, trigger.enqueue_messages
  end

  test "enqueue_messages cannot be true when reuse_session is false" do
    @trigger.reuse_session = false
    @trigger.enqueue_messages = true
    assert @trigger.valid? # before_validation callback clears it
    assert_equal false, @trigger.enqueue_messages
  end

  test "enqueue_messages can be true when reuse_session is true" do
    @trigger.reuse_session = true
    @trigger.enqueue_messages = true
    assert @trigger.valid?
    assert_equal true, @trigger.enqueue_messages
  end

  test "enqueue_messages is cleared when reuse_session is turned off" do
    @trigger.update!(reuse_session: true, enqueue_messages: true)
    assert @trigger.enqueue_messages

    @trigger.update!(reuse_session: false)
    assert_equal false, @trigger.reload.enqueue_messages
  end

  test "create_session! allows enqueue when running session has only sent messages" do
    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo",
      default_branch: "main",
      subdirectory: nil
    )
    AgentRootsConfig.stubs(:find!).with(@trigger.agent_root_name).returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    # Create a session and set up for reuse with enqueue_messages enabled
    session = @trigger.create_session!(prompt: "Initial prompt")
    @trigger.update!(reuse_session: true, enqueue_messages: true, last_session_id: session.id)

    # Simulate session being in running state
    session.update_column(:status, Session.statuses[:running])

    # Add a sent (not pending) enqueued message - this should not block new enqueues
    session.enqueued_messages.create!(content: "Already processed", position: 1, status: "sent")

    # Should still create an enqueued message since the existing one is "sent", not "pending"
    assert_difference("session.enqueued_messages.count", 1) do
      @trigger.create_session!(prompt: "Should be queued")
    end
  end

  # Resuscitate archived validation tests
  test "resuscitate_archived defaults to false" do
    trigger = Trigger.new(
      name: "Test",
      agent_root_name: "zimmer",
      prompt_template: "Test"
    )
    assert_equal false, trigger.resuscitate_archived
  end

  test "resuscitate_archived cannot be true when reuse_session is false" do
    @trigger.reuse_session = false
    @trigger.resuscitate_archived = true
    assert @trigger.valid? # before_validation callback clears it
    assert_equal false, @trigger.resuscitate_archived
  end

  test "resuscitate_archived can be true when reuse_session is true" do
    @trigger.reuse_session = true
    @trigger.resuscitate_archived = true
    assert @trigger.valid?
    assert_equal true, @trigger.resuscitate_archived
  end

  test "resuscitate_archived is cleared when reuse_session is turned off" do
    @trigger.update!(reuse_session: true, resuscitate_archived: true)
    assert @trigger.resuscitate_archived

    @trigger.update!(reuse_session: false)
    assert_equal false, @trigger.reload.resuscitate_archived
  end

  # Resuscitate archived session reuse tests
  test "create_session! resuscitates archived session when resuscitate_archived is true" do
    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo",
      default_branch: "main",
      subdirectory: nil
    )
    AgentRootsConfig.stubs(:find!).with(@trigger.agent_root_name).returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)
    AgentSessionJob.stubs(:enqueue_with_prompt)

    # Create initial session
    session = @trigger.create_session!(prompt: "Initial")
    @trigger.update!(reuse_session: true, resuscitate_archived: true, last_session_id: session.id)

    # Archive the session
    session.update_column(:status, Session.statuses[:archived])

    # Stub UnarchiveSessionService to simulate successful unarchive.
    # The service transitions the session to needs_input as a side effect,
    # which session.reload picks up after resuscitate_session! calls it.
    result = UnarchiveSessionService::Result.new(success?: true, session: session, clone_restored: false)
    UnarchiveSessionService.stubs(:call).with do |args|
      args[:session].update_column(:status, Session.statuses[:needs_input])
      true
    end.returns(result)

    # Should reuse the session instead of creating a new one
    assert_no_difference("Session.count") do
      reused = @trigger.create_session!(prompt: "Follow-up after resuscitation")
      assert_equal session.id, reused.id
    end
  end

  test "create_session! does NOT resuscitate failed session even when resuscitate_archived is true" do
    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo",
      default_branch: "main",
      subdirectory: nil
    )
    AgentRootsConfig.stubs(:find!).with(@trigger.agent_root_name).returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    # Create initial session
    session = @trigger.create_session!(prompt: "Initial")
    @trigger.update!(reuse_session: true, resuscitate_archived: true, last_session_id: session.id)

    # Fail the session (not archive it)
    session.update_column(:status, Session.statuses[:failed])

    # Should create a new session since failed is not resuscitable
    assert_difference("Session.count", 1) do
      new_session = @trigger.create_session!(prompt: "New prompt")
      assert_not_equal session.id, new_session.id
    end
  end

  test "create_session! raises when unarchive service fails during resuscitation" do
    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo",
      default_branch: "main",
      subdirectory: nil
    )
    AgentRootsConfig.stubs(:find!).with(@trigger.agent_root_name).returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    # Create initial session
    session = @trigger.create_session!(prompt: "Initial")
    @trigger.update!(reuse_session: true, resuscitate_archived: true, last_session_id: session.id)

    # Archive the session
    session.update_column(:status, Session.statuses[:archived])

    # Stub UnarchiveSessionService to simulate failure
    UnarchiveSessionService.stubs(:call).with(session: session).returns(
      UnarchiveSessionService::Result.new(success?: false, error: "Clone failed")
    )

    error = assert_raises(RuntimeError) do
      @trigger.create_session!(prompt: "Should fail")
    end
    assert_match(/Failed to resuscitate archived session/, error.message)
    assert_match(/Clone failed/, error.message)
  end

  # Trigger-wiring coverage for GitHub issue #4600.
  #
  # This exercises how create_session! HANDLES the resuscitation race outcome:
  # when UnarchiveSessionService reports the target session as an already-active
  # idempotent success (because a concurrent winner unarchived it and its job
  # advanced the row to running), create_session! must NOT raise in
  # resuscitate_session! and must proceed to follow_up_session! — reusing the
  # session and enqueuing the prompt.
  #
  # The service's OWN race handling — returning success rather than a failure for
  # an already-advanced winner — is what the #4600 fix changed, and it is covered
  # directly, without stubbing the service, by the entry-path and
  # transition_to_needs_input tests in
  # test/services/unarchive_session_service_test.rb. Here the service is stubbed
  # to that success contract so this test stays focused on the trigger wiring and
  # does not depend on a real git clone.
  test "create_session! does not raise when resuscitation observes an already-active winner (issue #4600)" do
    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo",
      default_branch: "main",
      subdirectory: nil
    )
    AgentRootsConfig.stubs(:find!).with(@trigger.agent_root_name).returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)
    AgentSessionJob.stubs(:enqueue_with_prompt)

    # Create initial session, then configure resuscitation + message enqueue so
    # the follow-up path has somewhere to land for an active (running) session.
    session = @trigger.create_session!(prompt: "Initial")
    @trigger.update!(
      reuse_session: true,
      resuscitate_archived: true,
      enqueue_messages: true,
      last_session_id: session.id
    )

    # The trigger's in-memory snapshot sees the session as archived and enters
    # the resuscitate path...
    session.update_column(:status, Session.statuses[:archived])

    # ...but the winning fire has already unarchived it and its job advanced the
    # row to running with archived_at cleared. Model that observable effect by
    # advancing the row when the (stubbed) service is invoked, and returning the
    # benign success Result the real service produces for this race (#4600). The
    # mutation is guarded on archived? so it is a safe idempotent no-op even if
    # Mocha evaluates the matcher block more than once.
    UnarchiveSessionService.stubs(:call).with do |args|
      s = args[:session]
      s.update_columns(status: Session.statuses[:running], archived_at: nil) if s.archived?
      true
    end.returns(UnarchiveSessionService::Result.new(success?: true, session: session, clone_restored: false))

    assert_nothing_raised do
      assert_no_difference("Session.count") do
        reused = @trigger.create_session!(prompt: "Follow-up after benign race")
        assert_equal session.id, reused.id
      end
    end

    # Follow-up was enqueued against the winner's running session (not dropped).
    assert_equal 1, session.enqueued_messages.where(status: "pending").count
  end

  test "create_session! creates new session when archived but resuscitate_archived is false" do
    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo",
      default_branch: "main",
      subdirectory: nil
    )
    AgentRootsConfig.stubs(:find!).with(@trigger.agent_root_name).returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    # Create initial session
    session = @trigger.create_session!(prompt: "Initial")
    @trigger.update!(reuse_session: true, resuscitate_archived: false, last_session_id: session.id)

    # Archive the session
    session.update_column(:status, Session.statuses[:archived])

    # Should create a new session since resuscitate_archived is off
    assert_difference("Session.count", 1) do
      new_session = @trigger.create_session!(prompt: "New prompt")
      assert_not_equal session.id, new_session.id
    end
  end

  # Self-healing stale MCP server tests
  test "create_session! removes stale MCP servers and creates session with valid ones" do
    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo",
      default_branch: "main",
      subdirectory: nil
    )
    AgentRootsConfig.stubs(:find!).with(@trigger.agent_root_name).returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    # Set up trigger with one valid and one stale server
    ServersConfig.stubs(:exists?).with("valid-server").returns(true)
    ServersConfig.stubs(:exists?).with("stale-server").returns(false)
    @trigger.update_column(:mcp_servers, [ "valid-server", "stale-server" ])
    AlertService.stubs(:raise_alert)

    session = @trigger.create_session!(prompt: "Test prompt")

    # Session should only have the valid server
    assert_equal [ "valid-server" ], session.mcp_servers

    # Trigger should be updated in the database
    @trigger.reload
    assert_equal [ "valid-server" ], @trigger.mcp_servers
  end

  test "create_session! removes all stale MCP servers and creates session with empty list" do
    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo",
      default_branch: "main",
      subdirectory: nil
    )
    AgentRootsConfig.stubs(:find!).with(@trigger.agent_root_name).returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    # Set up trigger with all stale servers
    ServersConfig.stubs(:exists?).with("stale-a").returns(false)
    ServersConfig.stubs(:exists?).with("stale-b").returns(false)
    @trigger.update_column(:mcp_servers, [ "stale-a", "stale-b" ])
    AlertService.stubs(:raise_alert)

    session = @trigger.create_session!(prompt: "Test prompt")

    # Session should have empty MCP servers
    assert_equal [], session.mcp_servers

    # Trigger should be updated in the database
    @trigger.reload
    assert_equal [], @trigger.mcp_servers
  end

  test "create_session! does not modify MCP servers when all are valid" do
    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo",
      default_branch: "main",
      subdirectory: nil
    )
    AgentRootsConfig.stubs(:find!).with(@trigger.agent_root_name).returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    # Set up trigger with all valid servers
    ServersConfig.stubs(:exists?).with("server-a").returns(true)
    ServersConfig.stubs(:exists?).with("server-b").returns(true)
    @trigger.update_column(:mcp_servers, [ "server-a", "server-b" ])

    session = @trigger.create_session!(prompt: "Test prompt")

    # Session should have both servers
    assert_equal [ "server-a", "server-b" ], session.mcp_servers

    # Trigger should remain unchanged
    @trigger.reload
    assert_equal [ "server-a", "server-b" ], @trigger.mcp_servers
  end

  test "create_session! raises alert when stale MCP servers are removed" do
    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo",
      default_branch: "main",
      subdirectory: nil
    )
    AgentRootsConfig.stubs(:find!).with(@trigger.agent_root_name).returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    # Set up trigger with one stale server
    ServersConfig.stubs(:exists?).with("valid-server").returns(true)
    ServersConfig.stubs(:exists?).with("gone-server").returns(false)
    @trigger.update_column(:mcp_servers, [ "valid-server", "gone-server" ])

    # Verify AlertService is called with expected arguments
    AlertService.expects(:raise_alert).with(
      "Trigger self-healed: stale MCP server(s) removed",
      has_entries(
        source: "Trigger#create_session!",
        dedup_key: "trigger_stale_mcp_#{@trigger.id}"
      )
    ).once

    @trigger.create_session!(prompt: "Test prompt")
  end

  test "create_session! persists stale MCP server removal to database" do
    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo",
      default_branch: "main",
      subdirectory: nil
    )
    AgentRootsConfig.stubs(:find!).with(@trigger.agent_root_name).returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)
    AlertService.stubs(:raise_alert)

    # Set up trigger with stale servers
    ServersConfig.stubs(:exists?).with("keeper").returns(true)
    ServersConfig.stubs(:exists?).with("removed-1").returns(false)
    ServersConfig.stubs(:exists?).with("removed-2").returns(false)
    @trigger.update_column(:mcp_servers, [ "keeper", "removed-1", "removed-2" ])

    @trigger.create_session!(prompt: "Test prompt")

    # Verify the database was updated (fresh load, not in-memory)
    db_trigger = Trigger.find(@trigger.id)
    assert_equal [ "keeper" ], db_trigger.mcp_servers
  end

  # === Tests for reusable_session? including waiting state ===

  test "create_session! reuses session when reuse_session is true and session is waiting" do
    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo",
      default_branch: "main",
      subdirectory: nil
    )
    AgentRootsConfig.stubs(:find!).with(@trigger.agent_root_name).returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)
    AgentSessionJob.stubs(:enqueue_with_prompt)

    session = @trigger.create_session!(prompt: "Initial prompt")
    @trigger.update!(reuse_session: true, last_session_id: session.id)

    session.update_column(:status, Session.statuses[:waiting])

    original_session_count = Session.count
    reused = @trigger.create_session!(prompt: "Follow-up prompt")

    assert_equal session.id, reused.id
    assert_equal original_session_count, Session.count
  end

  test "create_session! transitions waiting session to running before enqueuing follow-up" do
    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo",
      default_branch: "main",
      subdirectory: nil
    )
    AgentRootsConfig.stubs(:find!).with(@trigger.agent_root_name).returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)
    AgentSessionJob.stubs(:enqueue_with_prompt)

    session = @trigger.create_session!(prompt: "Initial prompt")
    @trigger.update!(reuse_session: true, last_session_id: session.id)

    session.update_column(:status, Session.statuses[:waiting])

    @trigger.create_session!(prompt: "Follow-up prompt")

    session.reload
    assert session.running?, "Expected session to be running after follow-up from waiting, but was #{session.status}"
  end

  # === Tests for one_time_reuse_trigger? ===

  test "one_time_reuse_trigger? returns true when reuse_session and all conditions are one-time schedules" do
    trigger = triggers(:one_time_schedule_trigger)
    trigger.update!(reuse_session: true)

    assert trigger.one_time_reuse_trigger?
  end

  test "one_time_reuse_trigger? returns false when reuse_session is false" do
    trigger = triggers(:one_time_schedule_trigger)
    trigger.update!(reuse_session: false)

    assert_not trigger.one_time_reuse_trigger?
  end

  test "one_time_reuse_trigger? returns false for recurring schedule trigger" do
    trigger = triggers(:enabled_schedule_trigger)
    trigger.update!(reuse_session: true)

    assert_not trigger.one_time_reuse_trigger?
  end

  test "one_time_reuse_trigger? returns false for slack trigger" do
    @trigger.update!(reuse_session: true)

    assert_not @trigger.one_time_reuse_trigger?
  end

  # === Tests for one-time reuse trigger skip logic ===

  test "create_session! skips for one-time reuse trigger when target session is not reusable" do
    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo",
      default_branch: "main",
      subdirectory: nil
    )
    AgentRootsConfig.stubs(:find!).with(@trigger.agent_root_name).returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    trigger = triggers(:one_time_schedule_trigger)
    trigger.update!(agent_root_name: @trigger.agent_root_name, reuse_session: true)

    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      agent_runtime: "claude_code",
      branch: "main",
      status: :failed
    )
    trigger.update!(last_session_id: session.id)

    assert_no_difference("Session.count") do
      result = trigger.create_session!(prompt: "Wake up")
      assert_equal session.id, result.id
    end
  end

  test "create_session! creates new session for recurring trigger when target is not reusable" do
    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo",
      default_branch: "main",
      subdirectory: nil
    )
    AgentRootsConfig.stubs(:find!).with(@trigger.agent_root_name).returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    trigger = triggers(:enabled_schedule_trigger)
    trigger.update!(reuse_session: true)

    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      agent_runtime: "claude_code",
      branch: "main",
      status: :failed
    )
    trigger.update!(last_session_id: session.id)

    assert_difference("Session.count", 1) do
      trigger.create_session!(prompt: "Regular check")
    end
  end

  # Self-healing stale agent root tests
  test "create_session! heals stale agent root when successor found via last session" do
    old_root_name = "old-agent-root"
    new_root_name = "new-agent-root"
    git_url = "https://github.com/test/repo"

    @trigger.update_columns(agent_root_name: old_root_name)

    # Create a last session that the trigger references
    last_session = Session.create!(
      prompt: "previous run",
      agent_runtime: "claude_code",
      git_root: git_url,
      subdirectory: "some/path",
      status: Session.statuses[:archived]
    )
    @trigger.update_columns(last_session_id: last_session.id)

    # Agent root doesn't exist under old name
    AgentRootsConfig.stubs(:exists?).with(old_root_name).returns(false)
    # But does exist under the new name (default stub returns true for other calls)

    # Set up a successor agent root matching the session's git_root and subdirectory
    successor = OpenStruct.new(
      name: new_root_name,
      url: git_url,
      default_branch: "main",
      subdirectory: "some/path"
    )
    AgentRootsConfig.stubs(:all).returns([ successor ])
    AgentRootsConfig.stubs(:find!).with(new_root_name).returns(successor)
    AgentSessionJob.stubs(:enqueue_new_session)
    AlertService.stubs(:raise_alert)

    session = @trigger.create_session!(prompt: "Test prompt")

    # Trigger should be updated to use the new agent root
    @trigger.reload
    assert_equal new_root_name, @trigger.agent_root_name

    # Session should have been created using the successor's git_root
    assert_equal git_url, session.git_root
  end

  test "create_session! raises error when agent root stale and no last session" do
    @trigger.update_columns(agent_root_name: "nonexistent-root", last_session_id: nil)
    AgentRootsConfig.stubs(:exists?).with("nonexistent-root").returns(false)

    error = assert_raises(AgentRootsConfig::AgentRootNotFoundError) do
      @trigger.create_session!(prompt: "Test")
    end
    assert_match(/no successor could be identified/, error.message)
  end

  test "create_session! raises error when agent root stale and last session has no matching root" do
    git_url = "https://github.com/test/repo"
    @trigger.update_columns(agent_root_name: "gone-root")

    last_session = Session.create!(
      prompt: "previous",
      agent_runtime: "claude_code",
      git_root: git_url,
      subdirectory: "some/path",
      status: Session.statuses[:archived]
    )
    @trigger.update_columns(last_session_id: last_session.id)

    AgentRootsConfig.stubs(:exists?).with("gone-root").returns(false)
    # Non-empty catalog, but no entry matches the session's git_root/subdirectory.
    # Using a non-empty list ensures the heal_stale_agent_root! guard against an
    # empty catalog (transient load failure) does not short-circuit the check.
    unrelated = OpenStruct.new(name: "unrelated-root", url: "https://github.com/other/repo", default_branch: "main", subdirectory: nil)
    AgentRootsConfig.stubs(:all).returns([ unrelated ])

    error = assert_raises(AgentRootsConfig::AgentRootNotFoundError) do
      @trigger.create_session!(prompt: "Test")
    end
    assert_match(/no successor could be identified/, error.message)
  end

  test "create_session! heals stale agent root without paging #eng-alerts" do
    # A found successor is matched on an exact git_root + subdirectory match, so
    # it is the SAME code location under a renamed catalog entry — the repoint
    # is impact-free and needs no human action. The heal is recorded via a
    # .warn log (obs audit trail) but must NOT raise an AlertService alert,
    # which would spam #eng-alerts on every recurrence (e.g. self-waking
    # sessions whose one-time wake triggers are recreated each fire carrying a
    # legacy/renamed root name). The unhealable branch still raises
    # AgentRootNotFoundError (→ .error → page), which IS correct — see the
    # assert_raises tests above and https://github.com/tadasant/zimmer-catalog/issues/4409.
    old_root_name = "old-root"
    new_root_name = "new-root"
    git_url = "https://github.com/test/repo"

    @trigger.update_columns(agent_root_name: old_root_name)

    last_session = Session.create!(
      prompt: "previous",
      agent_runtime: "claude_code",
      git_root: git_url,
      subdirectory: nil,
      status: Session.statuses[:archived]
    )
    @trigger.update_columns(last_session_id: last_session.id)

    AgentRootsConfig.stubs(:exists?).with(old_root_name).returns(false)
    successor = OpenStruct.new(name: new_root_name, url: git_url, default_branch: "main", subdirectory: nil)
    AgentRootsConfig.stubs(:all).returns([ successor ])
    AgentRootsConfig.stubs(:find!).with(new_root_name).returns(successor)
    AgentSessionJob.stubs(:enqueue_new_session)

    # Successful self-heal must be silent on #eng-alerts.
    AlertService.expects(:raise_alert).never

    session = @trigger.create_session!(prompt: "Test prompt")

    # The trigger is repointed to the successor and the session uses it.
    @trigger.reload
    assert_equal new_root_name, @trigger.agent_root_name
    assert_equal new_root_name, session.metadata["agent_root_key"]
  end

  # Self-healing stale catalog skills tests
  test "create_session! removes stale catalog skills and creates session" do
    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo",
      default_branch: "main",
      subdirectory: nil
    )
    AgentRootsConfig.stubs(:find!).with(@trigger.agent_root_name).returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)
    AlertService.stubs(:raise_alert)

    SkillsConfig.stubs(:exists?).with("valid-skill").returns(true)
    SkillsConfig.stubs(:exists?).with("stale-skill").returns(false)
    @trigger.update_column(:catalog_skills, [ "valid-skill", "stale-skill" ])

    session = @trigger.create_session!(prompt: "Test prompt")

    # Trigger should be updated in the database
    @trigger.reload
    assert_equal [ "valid-skill" ], @trigger.catalog_skills

    # Session should use the healed skills list
    assert_equal [ "valid-skill" ], session.catalog_skills
  end

  test "create_session! alerts when stale catalog skills are removed" do
    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo",
      default_branch: "main",
      subdirectory: nil
    )
    AgentRootsConfig.stubs(:find!).with(@trigger.agent_root_name).returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    SkillsConfig.stubs(:exists?).with("valid-skill").returns(true)
    SkillsConfig.stubs(:exists?).with("gone-skill").returns(false)
    @trigger.update_column(:catalog_skills, [ "valid-skill", "gone-skill" ])

    AlertService.expects(:raise_alert).with(
      "Trigger self-healed: stale catalog skill(s) removed",
      has_entries(
        source: "Trigger#create_session!",
        dedup_key: "trigger_stale_skills_#{@trigger.id}"
      )
    ).once

    @trigger.create_session!(prompt: "Test prompt")
  end

  # Self-healing stale catalog hooks tests
  test "create_session! removes stale catalog hooks and creates session" do
    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo",
      default_branch: "main",
      subdirectory: nil
    )
    AgentRootsConfig.stubs(:find!).with(@trigger.agent_root_name).returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)
    AlertService.stubs(:raise_alert)

    HooksConfig.stubs(:exists?).with("valid-hook").returns(true)
    HooksConfig.stubs(:exists?).with("stale-hook").returns(false)
    @trigger.update_column(:catalog_hooks, [ "valid-hook", "stale-hook" ])

    session = @trigger.create_session!(prompt: "Test prompt")

    @trigger.reload
    assert_equal [ "valid-hook" ], @trigger.catalog_hooks
    assert_equal [ "valid-hook" ], session.catalog_hooks
  end

  # === Tests for per-session wake-up auto-sleep ===

  test "validates last_session_id requires reuse_session" do
    target = Session.create!(git_root: "https://github.com/test/repo", agent_runtime: "claude_code", branch: "main", status: :needs_input)

    trigger = Trigger.new(
      name: "Per-session wake",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "Wake up",
      reuse_session: false,
      last_session_id: target.id,
      trigger_conditions_attributes: [
        { condition_type: "schedule", configuration: { "scheduled_at" => 1.hour.from_now.iso8601, "timezone" => "UTC" } }
      ]
    )

    assert_not trigger.valid?
    assert_includes trigger.errors[:last_session_id], "can only be set when re-use session is enabled"
  end

  test "after_create sleeps needs_input target session for per-session one-time trigger" do
    target = Session.create!(git_root: "https://github.com/test/repo", agent_runtime: "claude_code", branch: "main", status: :needs_input)

    trigger = Trigger.create!(
      name: "Per-session wake",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "Wake up",
      reuse_session: true,
      last_session_id: target.id,
      trigger_conditions_attributes: [
        { condition_type: "schedule", configuration: { "scheduled_at" => 1.hour.from_now.iso8601, "timezone" => "UTC" } }
      ]
    )

    target.reload
    assert_equal "waiting", target.status
    assert_equal trigger.id, Trigger.find(trigger.id).id # trigger persisted
  end

  test "after_create sets pending_sleep on running target session" do
    target = Session.create!(git_root: "https://github.com/test/repo", agent_runtime: "claude_code", branch: "main", status: :running)

    Trigger.create!(
      name: "Per-session wake",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "Wake up",
      reuse_session: true,
      last_session_id: target.id,
      trigger_conditions_attributes: [
        { condition_type: "schedule", configuration: { "scheduled_at" => 1.hour.from_now.iso8601, "timezone" => "UTC" } }
      ]
    )

    target.reload
    assert_equal "running", target.status
    assert_equal true, target.metadata&.dig("pending_sleep")
  end

  test "after_create is no-op when reuse_session is false" do
    target = Session.create!(git_root: "https://github.com/test/repo", agent_runtime: "claude_code", branch: "main", status: :needs_input)

    Trigger.create!(
      name: "Recurring",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "Recurring",
      reuse_session: false,
      trigger_conditions_attributes: [
        { condition_type: "schedule", configuration: { "scheduled_at" => 1.hour.from_now.iso8601, "timezone" => "UTC" } }
      ]
    )

    target.reload
    assert_equal "needs_input", target.status
  end

  test "after_create is no-op for recurring schedule trigger (no one-time condition)" do
    target = Session.create!(git_root: "https://github.com/test/repo", agent_runtime: "claude_code", branch: "main", status: :needs_input)

    Trigger.create!(
      name: "Hourly",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "Hourly",
      reuse_session: true,
      last_session_id: target.id,
      trigger_conditions_attributes: [
        { condition_type: "schedule", configuration: { "interval" => 1, "unit" => "hours", "timezone" => "UTC" } }
      ]
    )

    target.reload
    assert_equal "needs_input", target.status
  end

  test "after_create is no-op when trigger is disabled" do
    target = Session.create!(git_root: "https://github.com/test/repo", agent_runtime: "claude_code", branch: "main", status: :needs_input)

    Trigger.create!(
      name: "Disabled wake",
      status: "disabled",
      agent_root_name: "zimmer",
      prompt_template: "Wake up",
      reuse_session: true,
      last_session_id: target.id,
      trigger_conditions_attributes: [
        { condition_type: "schedule", configuration: { "scheduled_at" => 1.hour.from_now.iso8601, "timezone" => "UTC" } }
      ]
    )

    target.reload
    assert_equal "needs_input", target.status
  end

  test "after_create sleeps needs_input target session for session-scoped ao_event trigger" do
    target = Session.create!(git_root: "https://github.com/test/repo", agent_runtime: "claude_code", branch: "main", status: :needs_input)
    watched = Session.create!(git_root: "https://github.com/test/repo", agent_runtime: "claude_code", branch: "main", status: :running)

    trigger = Trigger.create!(
      name: "Wake on watched session",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "Wake up",
      reuse_session: true,
      last_session_id: target.id,
      trigger_conditions_attributes: [
        {
          condition_type: "ao_event",
          configuration: { "event_name" => "session_needs_input", "watched_session_id" => watched.id }
        }
      ]
    )

    target.reload
    assert_equal "waiting", target.status
    assert_equal trigger.id, Trigger.find(trigger.id).id
  end

  test "after_create is no-op for broadcast (no watched_session_id) ao_event trigger" do
    target = Session.create!(git_root: "https://github.com/test/repo", agent_runtime: "claude_code", branch: "main", status: :needs_input)

    Trigger.create!(
      name: "Broadcast ao_event",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "Broadcast",
      reuse_session: true,
      last_session_id: target.id,
      trigger_conditions_attributes: [
        { condition_type: "ao_event", configuration: { "event_name" => "session_needs_input" } }
      ]
    )

    target.reload
    assert_equal "needs_input", target.status, "Broadcast ao_event triggers should not auto-sleep target"
  end

  test "one_time_reuse_trigger? returns true for session-scoped ao_event" do
    target = Session.create!(git_root: "https://github.com/test/repo", agent_runtime: "claude_code", branch: "main", status: :needs_input)
    watched = Session.create!(git_root: "https://github.com/test/repo", agent_runtime: "claude_code", branch: "main", status: :running)

    trigger = Trigger.create!(
      name: "Per-session ao_event wake",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "Wake up",
      reuse_session: true,
      last_session_id: target.id,
      trigger_conditions_attributes: [
        {
          condition_type: "ao_event",
          configuration: { "event_name" => "session_needs_input", "watched_session_id" => watched.id }
        }
      ]
    )

    assert trigger.one_time_reuse_trigger?
  end

  test "after_create skips auto-sleep when target session is in waiting state already" do
    target = Session.create!(git_root: "https://github.com/test/repo", agent_runtime: "claude_code", branch: "main", status: :waiting)

    assert_nothing_raised do
      Trigger.create!(
        name: "Per-session wake",
        status: "enabled",
        agent_root_name: "zimmer",
        prompt_template: "Wake up",
        reuse_session: true,
        last_session_id: target.id,
        trigger_conditions_attributes: [
          { condition_type: "schedule", configuration: { "scheduled_at" => 1.hour.from_now.iso8601, "timezone" => "UTC" } }
        ]
      )
    end

    target.reload
    assert_equal "waiting", target.status
  end

  # === Tests for destroy_sibling_wakes! ===

  test "destroy_sibling_wakes! destroys other one-time reuse triggers with same last_session_id" do
    requester = Session.create!(git_root: "https://github.com/test/repo", agent_runtime: "claude_code", branch: "main", status: :waiting)
    watched = Session.create!(git_root: "https://github.com/test/repo", agent_runtime: "claude_code", branch: "main", status: :running)

    needs_input_wake = Trigger.create!(
      name: "Wake on needs_input",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "go",
      reuse_session: true,
      last_session_id: requester.id,
      trigger_conditions_attributes: [
        { condition_type: "ao_event", configuration: { "event_name" => "session_needs_input", "watched_session_id" => watched.id } }
      ]
    )

    failed_wake = Trigger.create!(
      name: "Wake on failed",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "go",
      reuse_session: true,
      last_session_id: requester.id,
      trigger_conditions_attributes: [
        { condition_type: "ao_event", configuration: { "event_name" => "session_failed", "watched_session_id" => watched.id } }
      ]
    )

    deadline = Trigger.create!(
      name: "Deadline backstop",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "go",
      reuse_session: true,
      last_session_id: requester.id,
      trigger_conditions_attributes: [
        { condition_type: "schedule", configuration: { "scheduled_at" => 1.hour.from_now.iso8601, "timezone" => "UTC" } }
      ]
    )

    destroyed = needs_input_wake.destroy_sibling_wakes!

    assert_equal 2, destroyed
    assert_not Trigger.exists?(failed_wake.id), "sibling failed_wake should be destroyed"
    assert_not Trigger.exists?(deadline.id), "sibling deadline backstop should be destroyed"
    assert Trigger.exists?(needs_input_wake.id), "the firing trigger itself is not destroyed by destroy_sibling_wakes!"
  end

  test "destroy_sibling_wakes! does not destroy triggers for a different requester" do
    requester_a = Session.create!(git_root: "https://github.com/test/repo", agent_runtime: "claude_code", branch: "main", status: :waiting)
    requester_b = Session.create!(git_root: "https://github.com/test/repo", agent_runtime: "claude_code", branch: "main", status: :waiting)
    watched = Session.create!(git_root: "https://github.com/test/repo", agent_runtime: "claude_code", branch: "main", status: :running)

    wake_a = Trigger.create!(
      name: "Wake A",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "go",
      reuse_session: true,
      last_session_id: requester_a.id,
      trigger_conditions_attributes: [
        { condition_type: "ao_event", configuration: { "event_name" => "session_needs_input", "watched_session_id" => watched.id } }
      ]
    )

    wake_b = Trigger.create!(
      name: "Wake B",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "go",
      reuse_session: true,
      last_session_id: requester_b.id,
      trigger_conditions_attributes: [
        { condition_type: "ao_event", configuration: { "event_name" => "session_failed", "watched_session_id" => watched.id } }
      ]
    )

    destroyed = wake_a.destroy_sibling_wakes!

    assert_equal 0, destroyed
    assert Trigger.exists?(wake_b.id), "wake for a different requester must be left alone"
  end

  test "destroy_sibling_wakes! does not destroy recurring triggers (not one_time_reuse_trigger?)" do
    requester = Session.create!(git_root: "https://github.com/test/repo", agent_runtime: "claude_code", branch: "main", status: :waiting)
    watched = Session.create!(git_root: "https://github.com/test/repo", agent_runtime: "claude_code", branch: "main", status: :running)

    one_time_wake = Trigger.create!(
      name: "One-time wake",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "go",
      reuse_session: true,
      last_session_id: requester.id,
      trigger_conditions_attributes: [
        { condition_type: "ao_event", configuration: { "event_name" => "session_needs_input", "watched_session_id" => watched.id } }
      ]
    )

    recurring_trigger = Trigger.create!(
      name: "Recurring (broadcast ao_event) referencing same requester",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "go",
      reuse_session: true,
      last_session_id: requester.id,
      trigger_conditions_attributes: [
        { condition_type: "ao_event", configuration: { "event_name" => "session_needs_input" } }
      ]
    )

    destroyed = one_time_wake.destroy_sibling_wakes!

    assert_equal 0, destroyed
    assert Trigger.exists?(recurring_trigger.id), "broadcast/recurring trigger must be left alone"
  end

  test "destroy_sibling_wakes! is a no-op for triggers that aren't one-time-reuse" do
    requester = Session.create!(git_root: "https://github.com/test/repo", agent_runtime: "claude_code", branch: "main", status: :waiting)

    sibling = Trigger.create!(
      name: "Sibling wake",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "go",
      reuse_session: true,
      last_session_id: requester.id,
      trigger_conditions_attributes: [
        { condition_type: "schedule", configuration: { "scheduled_at" => 1.hour.from_now.iso8601, "timezone" => "UTC" } }
      ]
    )

    # Recurring trigger should not destroy anything when it "fires"
    @trigger.update!(reuse_session: true, last_session_id: requester.id)
    assert_not @trigger.one_time_reuse_trigger?

    destroyed = @trigger.destroy_sibling_wakes!

    assert_equal 0, destroyed
    assert Trigger.exists?(sibling.id), "siblings should not be destroyed when caller is recurring"
  end

  test "destroy_sibling_wakes! returns 0 when no last_session_id" do
    @trigger.update!(reuse_session: true, last_session_id: nil)
    assert_equal 0, @trigger.destroy_sibling_wakes!
  end

  # Self-healing stale catalog plugins tests
  test "create_session! removes stale catalog plugins and creates session" do
    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo",
      default_branch: "main",
      subdirectory: nil
    )
    AgentRootsConfig.stubs(:find!).with(@trigger.agent_root_name).returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)
    AlertService.stubs(:raise_alert)

    PluginsConfig.stubs(:exists?).with("valid-plugin").returns(true)
    PluginsConfig.stubs(:exists?).with("stale-plugin").returns(false)
    @trigger.update_column(:catalog_plugins, [ "valid-plugin", "stale-plugin" ])

    session = @trigger.create_session!(prompt: "Test prompt")

    @trigger.reload
    assert_equal [ "valid-plugin" ], @trigger.catalog_plugins
    assert_equal [ "valid-plugin" ], session.catalog_plugins
  end

  # === Tests for fire_ao_event_immediately_if_state_matches ===
  #
  # Cover the "fire on current state" semantics added to close the wake-loop
  # race where, e.g., a requester registers a session_needs_input watcher on
  # a session that has already paused. The transition has already happened,
  # so the trigger would otherwise sleep forever (or until a deadline backstop).

  test "after_create fires immediately when watched session is already in needs_input" do
    requester = Session.create!(git_root: "https://github.com/test/repo", agent_runtime: "claude_code", branch: "main", status: :needs_input)
    watched = Session.create!(git_root: "https://github.com/test/repo", agent_runtime: "claude_code", branch: "main", status: :needs_input)

    assert_enqueued_with(job: AoEventTriggerJob, args: [ "session_needs_input", watched.id ]) do
      Trigger.create!(
        name: "Wake on already-needs_input",
        status: "enabled",
        agent_root_name: "zimmer",
        prompt_template: "Wake up",
        reuse_session: true,
        last_session_id: requester.id,
        trigger_conditions_attributes: [
          {
            condition_type: "ao_event",
            configuration: { "event_name" => "session_needs_input", "watched_session_id" => watched.id }
          }
        ]
      )
    end
  end

  test "after_create fires immediately when watched session is already failed (previously rejected combo)" do
    requester = Session.create!(git_root: "https://github.com/test/repo", agent_runtime: "claude_code", branch: "main", status: :needs_input)
    watched = Session.create!(git_root: "https://github.com/test/repo", agent_runtime: "claude_code", branch: "main", status: :failed)

    assert_enqueued_with(job: AoEventTriggerJob, args: [ "session_failed", watched.id ]) do
      Trigger.create!(
        name: "Wake on already-failed",
        status: "enabled",
        agent_root_name: "zimmer",
        prompt_template: "Wake up",
        reuse_session: true,
        last_session_id: requester.id,
        trigger_conditions_attributes: [
          {
            condition_type: "ao_event",
            configuration: { "event_name" => "session_failed", "watched_session_id" => watched.id }
          }
        ]
      )
    end
  end

  test "after_create fires immediately when watched session is already archived (previously rejected combo)" do
    requester = Session.create!(git_root: "https://github.com/test/repo", agent_runtime: "claude_code", branch: "main", status: :needs_input)
    watched = Session.create!(git_root: "https://github.com/test/repo", agent_runtime: "claude_code", branch: "main", status: :archived)

    assert_enqueued_with(job: AoEventTriggerJob, args: [ "session_archived", watched.id ]) do
      Trigger.create!(
        name: "Wake on already-archived",
        status: "enabled",
        agent_root_name: "zimmer",
        prompt_template: "Wake up",
        reuse_session: true,
        last_session_id: requester.id,
        trigger_conditions_attributes: [
          {
            condition_type: "ao_event",
            configuration: { "event_name" => "session_archived", "watched_session_id" => watched.id }
          }
        ]
      )
    end
  end

  test "after_create does NOT fire immediately when watched session state does not match" do
    requester = Session.create!(git_root: "https://github.com/test/repo", agent_runtime: "claude_code", branch: "main", status: :needs_input)
    watched = Session.create!(git_root: "https://github.com/test/repo", agent_runtime: "claude_code", branch: "main", status: :running)

    assert_no_enqueued_jobs(only: AoEventTriggerJob) do
      Trigger.create!(
        name: "Wake on mismatched state",
        status: "enabled",
        agent_root_name: "zimmer",
        prompt_template: "Wake up",
        reuse_session: true,
        last_session_id: requester.id,
        trigger_conditions_attributes: [
          {
            condition_type: "ao_event",
            configuration: { "event_name" => "session_needs_input", "watched_session_id" => watched.id }
          }
        ]
      )
    end
  end

  test "after_create does NOT fire immediately for broadcast (unscoped) ao_event conditions" do
    requester = Session.create!(git_root: "https://github.com/test/repo", agent_runtime: "claude_code", branch: "main", status: :needs_input)

    assert_no_enqueued_jobs(only: AoEventTriggerJob) do
      Trigger.create!(
        name: "Broadcast wake",
        status: "enabled",
        agent_root_name: "zimmer",
        prompt_template: "Wake up",
        reuse_session: true,
        last_session_id: requester.id,
        trigger_conditions_attributes: [
          { condition_type: "ao_event", configuration: { "event_name" => "session_needs_input" } }
        ]
      )
    end
  end

  test "after_create does NOT fire immediately for disabled triggers" do
    requester = Session.create!(git_root: "https://github.com/test/repo", agent_runtime: "claude_code", branch: "main", status: :needs_input)
    watched = Session.create!(git_root: "https://github.com/test/repo", agent_runtime: "claude_code", branch: "main", status: :needs_input)

    assert_no_enqueued_jobs(only: AoEventTriggerJob) do
      Trigger.create!(
        name: "Disabled wake",
        status: "disabled",
        agent_root_name: "zimmer",
        prompt_template: "Wake up",
        reuse_session: true,
        last_session_id: requester.id,
        trigger_conditions_attributes: [
          {
            condition_type: "ao_event",
            configuration: { "event_name" => "session_needs_input", "watched_session_id" => watched.id }
          }
        ]
      )
    end
  end

  test "after_create acquires FOR UPDATE lock on watched session for atomicity" do
    # The atomic check relies on Session.lock to serialize against concurrent
    # state transitions. Verify the lock is taken — the integration ordering
    # is that the lock is acquired INSIDE the trigger's create transaction,
    # and the AoEventTriggerJob enqueue is deferred via after_all_transactions_commit
    # so it doesn't run until the trigger row is committed.
    requester = Session.create!(git_root: "https://github.com/test/repo", agent_runtime: "claude_code", branch: "main", status: :needs_input)
    watched = Session.create!(git_root: "https://github.com/test/repo", agent_runtime: "claude_code", branch: "main", status: :needs_input)

    locked_relation_called = false
    Session.singleton_class.send(:alias_method, :__lock_orig_for_test, :lock)
    Session.singleton_class.send(:define_method, :lock) do |*args, &block|
      locked_relation_called = true
      __lock_orig_for_test(*args, &block)
    end

    begin
      Trigger.create!(
        name: "Lock test wake",
        status: "enabled",
        agent_root_name: "zimmer",
        prompt_template: "Wake up",
        reuse_session: true,
        last_session_id: requester.id,
        trigger_conditions_attributes: [
          {
            condition_type: "ao_event",
            configuration: { "event_name" => "session_needs_input", "watched_session_id" => watched.id }
          }
        ]
      )
    ensure
      Session.singleton_class.send(:alias_method, :lock, :__lock_orig_for_test)
      Session.singleton_class.send(:remove_method, :__lock_orig_for_test)
    end

    assert locked_relation_called, "Expected Session.lock to be called for atomic state check"
  end

  test "after_create immediate-fire skips silently if watched session row is missing at lock time" do
    # Simulates a race where the watched session is destroyed between the
    # condition validation (which checks existence) and the after_create
    # callback firing. We force this by stubbing Session.lock to return a
    # relation whose find_by returns nil — no enqueue, no crash.
    requester = Session.create!(git_root: "https://github.com/test/repo", agent_runtime: "claude_code", branch: "main", status: :needs_input)
    watched = Session.create!(git_root: "https://github.com/test/repo", agent_runtime: "claude_code", branch: "main", status: :needs_input)

    locked_relation_stub = Object.new
    locked_relation_stub.define_singleton_method(:find_by) { |_| nil }

    Session.singleton_class.send(:alias_method, :__lock_orig_missing_test, :lock)
    Session.singleton_class.define_method(:lock) { |*| locked_relation_stub }

    trigger = nil
    begin
      assert_no_enqueued_jobs(only: AoEventTriggerJob) do
        assert_nothing_raised do
          trigger = Trigger.create!(
            name: "Wake on missing-watched",
            status: "enabled",
            agent_root_name: "zimmer",
            prompt_template: "Wake up",
            reuse_session: true,
            last_session_id: requester.id,
            trigger_conditions_attributes: [
              {
                condition_type: "ao_event",
                configuration: { "event_name" => "session_needs_input", "watched_session_id" => watched.id }
              }
            ]
          )
        end
      end
    ensure
      Session.singleton_class.send(:alias_method, :lock, :__lock_orig_missing_test)
      Session.singleton_class.send(:remove_method, :__lock_orig_missing_test)
    end

    refute_nil trigger
  end

  # === Self-watch validation ===

  test "rejects creating a trigger where watched_session_id equals last_session_id" do
    requester = Session.create!(git_root: "https://github.com/test/repo", agent_runtime: "claude_code", branch: "main", status: :needs_input)

    trigger = Trigger.new(
      name: "Self-watch (invalid)",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "Wake up",
      reuse_session: true,
      last_session_id: requester.id,
      trigger_conditions_attributes: [
        {
          condition_type: "ao_event",
          configuration: { "event_name" => "session_needs_input", "watched_session_id" => requester.id }
        }
      ]
    )

    assert_not trigger.valid?
    assert trigger.errors[:base].any? { |msg| msg.include?("cannot equal last_session_id") },
      "Expected self-watch error, got: #{trigger.errors.full_messages.inspect}"
  end

  test "rejects self-watch for session_failed event too" do
    requester = Session.create!(git_root: "https://github.com/test/repo", agent_runtime: "claude_code", branch: "main", status: :needs_input)

    trigger = Trigger.new(
      name: "Self-watch failed (invalid)",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "Wake up",
      reuse_session: true,
      last_session_id: requester.id,
      trigger_conditions_attributes: [
        {
          condition_type: "ao_event",
          configuration: { "event_name" => "session_failed", "watched_session_id" => requester.id }
        }
      ]
    )

    assert_not trigger.valid?
    assert trigger.errors[:base].any? { |msg| msg.include?("cannot equal last_session_id") }
  end

  test "rejects self-watch for session_archived event too" do
    requester = Session.create!(git_root: "https://github.com/test/repo", agent_runtime: "claude_code", branch: "main", status: :needs_input)

    trigger = Trigger.new(
      name: "Self-watch archived (invalid)",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "Wake up",
      reuse_session: true,
      last_session_id: requester.id,
      trigger_conditions_attributes: [
        {
          condition_type: "ao_event",
          configuration: { "event_name" => "session_archived", "watched_session_id" => requester.id }
        }
      ]
    )

    assert_not trigger.valid?
    assert trigger.errors[:base].any? { |msg| msg.include?("cannot equal last_session_id") }
  end

  # === Tests for last_follow_up_status / last_follow_up_dropped? ===
  #
  # The status flag is the in-memory signal callers (AoEventTriggerJob,
  # ScheduleTriggerJob) use to decide whether destroying sibling wake
  # triggers is safe. If follow_up_session! silently dropped the prompt,
  # destroying siblings would leave the requester with no wakes at all —
  # which is the cycle-18 bug this fix exists to prevent.

  test "last_follow_up_dropped? is false before follow_up_session! has been called" do
    assert_equal false, @trigger.last_follow_up_dropped?
    assert_nil @trigger.last_follow_up_status
  end

  test "follow_up_session! sets :delivered when reusing a needs_input session" do
    mock_agent_root = OpenStruct.new(url: "https://github.com/test/repo", default_branch: "main", subdirectory: nil)
    AgentRootsConfig.stubs(:find!).returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)
    AgentSessionJob.stubs(:enqueue_with_prompt)

    session = @trigger.create_session!(prompt: "Initial")
    @trigger.update!(reuse_session: true, last_session_id: session.id)
    session.update_column(:status, Session.statuses[:needs_input])

    @trigger.create_session!(prompt: "Follow-up")

    assert_equal :delivered, @trigger.last_follow_up_status
    assert_equal false, @trigger.last_follow_up_dropped?
  end

  test "follow_up_session! sets :queued when reusing a running session with enqueue_messages enabled" do
    mock_agent_root = OpenStruct.new(url: "https://github.com/test/repo", default_branch: "main", subdirectory: nil)
    AgentRootsConfig.stubs(:find!).returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    session = @trigger.create_session!(prompt: "Initial")
    @trigger.update!(reuse_session: true, enqueue_messages: true, last_session_id: session.id)
    session.update_column(:status, Session.statuses[:running])

    @trigger.create_session!(prompt: "Queued")

    assert_equal :queued, @trigger.last_follow_up_status
    assert_equal false, @trigger.last_follow_up_dropped?
  end

  test "follow_up_session! sets :skipped_pending_exists when a pending message already exists" do
    mock_agent_root = OpenStruct.new(url: "https://github.com/test/repo", default_branch: "main", subdirectory: nil)
    AgentRootsConfig.stubs(:find!).returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    session = @trigger.create_session!(prompt: "Initial")
    @trigger.update!(reuse_session: true, enqueue_messages: true, last_session_id: session.id)
    session.update_column(:status, Session.statuses[:running])
    session.enqueued_messages.create!(content: "Already queued", position: 1, status: "pending")

    @trigger.create_session!(prompt: "Should be skipped")

    assert_equal :skipped_pending_exists, @trigger.last_follow_up_status
    assert_equal false, @trigger.last_follow_up_dropped?
  end

  test "follow_up_session! sets :dropped for recurring trigger + busy session + enqueue disabled" do
    # The legacy silent-drop case: recurring (not one_time_reuse_trigger?)
    # trigger, requester is running, enqueue_messages disabled. Nothing can
    # be done with the prompt — but the caller can now see this via
    # last_follow_up_dropped?.
    mock_agent_root = OpenStruct.new(url: "https://github.com/test/repo", default_branch: "main", subdirectory: nil)
    AgentRootsConfig.stubs(:find!).returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    session = @trigger.create_session!(prompt: "Initial")
    # @trigger is :enabled_slack_trigger — slack condition → NOT one_time_reuse_trigger
    @trigger.update!(reuse_session: true, enqueue_messages: false, last_session_id: session.id)
    session.update_column(:status, Session.statuses[:running])

    assert_not @trigger.one_time_reuse_trigger?, "Sanity check: slack trigger is not one_time_reuse"

    @trigger.create_session!(prompt: "Will be dropped")

    assert_equal :dropped, @trigger.last_follow_up_status
    assert_equal true, @trigger.last_follow_up_dropped?
  end

  # === Tests for wake-up queuing override (primary fix) ===
  #
  # One-time-reuse triggers (wake-ups) must queue the prompt even when
  # enqueue_messages is false — they're one-shot signals, not recurring
  # drumbeats, so the "don't barge a busy session" intent of
  # enqueue_messages: false does not apply.

  test "follow_up_session! queues wake-up message for running requester even when enqueue_messages is false" do
    requester = Session.create!(
      git_root: "https://github.com/test/repo",
      agent_runtime: "claude_code",
      branch: "main",
      status: :running
    )
    watched = Session.create!(
      git_root: "https://github.com/test/repo",
      agent_runtime: "claude_code",
      branch: "main",
      status: :running
    )

    # One-time wake: session-scoped ao_event condition, reuse_session true,
    # enqueue_messages NOT set (defaults to false). This mirrors the trigger
    # created by mcp__agent-orchestrator-prod__wake_me_up_when_session_changes_state.
    wake_trigger = Trigger.create!(
      name: "Wake on watched needs_input",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "Watched session reached {{event}}",
      reuse_session: true,
      last_session_id: requester.id,
      trigger_conditions_attributes: [
        { condition_type: "ao_event", configuration: { "event_name" => "session_needs_input", "watched_session_id" => watched.id } }
      ]
    )

    assert wake_trigger.one_time_reuse_trigger?, "Sanity check: trigger is a one-time wake"
    assert_equal false, wake_trigger.enqueue_messages, "Sanity check: enqueue_messages defaults to false"

    mock_agent_root = OpenStruct.new(url: "https://github.com/test/repo", default_branch: "main", subdirectory: nil)
    AgentRootsConfig.stubs(:find!).returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    assert_difference("requester.enqueued_messages.count", 1) do
      wake_trigger.create_session!(prompt: "Wake up: watched paused")
    end

    enqueued = requester.enqueued_messages.last
    assert_equal "Wake up: watched paused", enqueued.content
    assert_equal "pending", enqueued.status
    assert_equal :queued, wake_trigger.last_follow_up_status
    assert_equal false, wake_trigger.last_follow_up_dropped?
  end

  # === Tests for the bookkeeping-write TOCTOU race (issue #3919) ===
  #
  # Internal bookkeeping writes (last_triggered_at / last_session_id) must NOT
  # run create-time/presence validations. A sibling wake firing concurrently
  # calls #destroy_sibling_wakes!, which destroys this trigger and
  # cascade-deletes its conditions out from under a still-in-memory instance
  # being processed by ScheduleTriggerJob/AoEventTriggerJob. A full-validation
  # save! would then re-run `validates :trigger_conditions, presence:`, find
  # zero conditions in the DB, and raise RecordInvalid — producing a spurious
  # ".error" alert for a benign, self-correcting race. These writes use
  # update_columns to skip validations/callbacks.

  test "follow_up_session! bookkeeping write does not raise when conditions are deleted mid-flight" do
    requester = Session.create!(
      git_root: "https://github.com/test/repo",
      agent_runtime: "claude_code",
      branch: "main",
      status: :needs_input
    )
    watched = Session.create!(
      git_root: "https://github.com/test/repo",
      agent_runtime: "claude_code",
      branch: "main",
      status: :running
    )

    wake_trigger = Trigger.create!(
      name: "Wake on watched needs_input",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "Watched session reached {{event}}",
      reuse_session: true,
      last_session_id: requester.id,
      trigger_conditions_attributes: [
        { condition_type: "ao_event", configuration: { "event_name" => "session_needs_input", "watched_session_id" => watched.id } }
      ]
    )

    AgentSessionJob.stubs(:enqueue_with_prompt)

    # Reload fresh so trigger_conditions is unloaded (mirrors how the firing
    # jobs hold the trigger), then simulate a concurrent sibling wake's
    # destroy_sibling_wakes! cascade deleting this trigger's only condition.
    trigger = Trigger.find(wake_trigger.id)
    TriggerCondition.where(trigger_id: trigger.id).delete_all

    # Sanity: a full-validation save WOULD trip the presence validation now
    # that the conditions are gone — this is the bug being fixed.
    stale = Trigger.find(trigger.id)
    assert_not stale.update(last_triggered_at: Time.current),
      "Sanity: full-validation save trips trigger_conditions presence when conditions are gone"
    assert_includes stale.errors[:trigger_conditions], "must have at least one condition"

    # The reuse/follow-up path must complete without raising and advance the
    # bookkeeping timestamp via update_columns.
    assert_nothing_raised do
      trigger.create_session!(prompt: "Wake up: watched paused")
    end

    assert_not_nil trigger.reload.last_triggered_at,
      "last_triggered_at should be advanced even when conditions were deleted mid-flight"
  end

  test "create_new_session! bookkeeping write does not raise when conditions are deleted mid-flight" do
    mock_agent_root = OpenStruct.new(url: "https://github.com/test/repo", default_branch: "main", subdirectory: nil)
    AgentRootsConfig.stubs(:find!).returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    sched_trigger = Trigger.create!(
      name: "One-time schedule new-session",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "Scheduled run",
      reuse_session: false,
      trigger_conditions_attributes: [
        { condition_type: "schedule", configuration: { "scheduled_at" => 1.minute.ago.iso8601 } }
      ]
    )

    # Reload fresh, then simulate concurrent sibling-wake cleanup cascade.
    trigger = Trigger.find(sched_trigger.id)
    TriggerCondition.where(trigger_id: trigger.id).delete_all

    session = nil
    assert_nothing_raised do
      session = trigger.create_session!(prompt: "Scheduled run")
    end

    assert_not_nil session, "a new session should be created on the create_new_session! path"
    trigger.reload
    assert_not_nil trigger.last_triggered_at,
      "last_triggered_at should be advanced even when conditions were deleted mid-flight"
    assert_equal session.id, trigger.last_session_id,
      "last_session_id should be tracked via update_columns despite reuse_session: false"
  end

  # ---------------------------------------------------------------------------
  # Artifact sync must never silently strip a reused session's MCP servers.
  #
  # Regression for the "long-running session silently lost its MCP servers"
  # defect (production session 9563). A wake trigger created via
  # POST /api/v1/triggers (the `wake_me_up_later` /
  # `wake_me_up_when_session_changes_state` self-session tools) never declares
  # artifacts, so its jsonb columns default to []. When it fired,
  # follow_up_session! synced that empty list onto the live session, wiping
  # every user-provisioned MCP server mid-conversation with no log line.
  # ---------------------------------------------------------------------------

  def build_wake_trigger(session)
    watched = Session.create!(
      prompt: "Watched downstream session",
      git_root: "https://github.com/test/repo",
      branch: "main"
    )

    Trigger.create!(
      name: "Wake me when session #{session.id} needs input",
      status: "enabled",
      agent_root_name: "agent-orchestrator",
      prompt_template: "The watched session transitioned.",
      reuse_session: true,
      last_session_id: session.id,
      mcp_servers: [],
      catalog_skills: [],
      catalog_hooks: [],
      catalog_plugins: [],
      trigger_conditions_attributes: [
        {
          condition_type: "ao_event",
          configuration: { "event_name" => "session_needs_input", "watched_session_id" => watched.id }
        }
      ]
    ).reload
  end

  def build_reusable_session(mcp_servers:, catalog_skills: [])
    session = Session.create!(
      prompt: "Long-running task",
      git_root: "https://github.com/test/repo",
      branch: "main",
      mcp_servers: mcp_servers,
      catalog_skills: catalog_skills
    )
    session.update_column(:status, Session.statuses[:needs_input])
    session
  end

  test "one-time wake trigger does not strip MCP servers from the session it reuses" do
    AgentSessionJob.stubs(:enqueue_with_prompt)

    session = build_reusable_session(
      mcp_servers: [ "agent-orchestrator-prod-sessions", "digitalocean-tadasant", "tailscale-readwrite" ]
    )
    trigger = build_wake_trigger(session)
    assert trigger.one_time_reuse_trigger?, "fixture should be a one-time reuse (wake) trigger"

    trigger.create_session!(prompt: "Wake up")

    assert_equal(
      [ "agent-orchestrator-prod-sessions", "digitalocean-tadasant", "tailscale-readwrite" ],
      session.reload.mcp_servers,
      "a wake trigger must not overwrite the reused session's MCP servers with its own empty list"
    )
  end

  test "one-time wake trigger does not strip catalog skills from the session it reuses" do
    AgentSessionJob.stubs(:enqueue_with_prompt)

    session = build_reusable_session(mcp_servers: [ "slack-workspace" ], catalog_skills: [ "zimmer-run-tests" ])
    trigger = build_wake_trigger(session)

    trigger.create_session!(prompt: "Wake up")

    assert_equal [ "zimmer-run-tests" ], session.reload.catalog_skills,
      "a wake trigger must not overwrite the reused session's catalog skills"
  end

  test "recurring reuse trigger with no MCP servers does not wipe the session's servers" do
    AgentSessionJob.stubs(:enqueue_with_prompt)

    session = build_reusable_session(mcp_servers: [ "slack-workspace", "digitalocean-tadasant" ])

    # disabled_slack_trigger has mcp_servers: [] and a recurring slack condition,
    # so it is NOT a one-time reuse trigger — it exercises the second guard.
    trigger = triggers(:disabled_slack_trigger)
    trigger.update!(status: "enabled", reuse_session: true, last_session_id: session.id)
    assert_not trigger.one_time_reuse_trigger?

    trigger.create_session!(prompt: "Follow-up")

    assert_equal [ "slack-workspace", "digitalocean-tadasant" ], session.reload.mcp_servers,
      "an empty trigger server list must never be synced over a non-empty session list"
  end

  test "recurring reuse trigger still syncs a non-empty MCP server list onto the session" do
    AgentSessionJob.stubs(:enqueue_with_prompt)

    session = build_reusable_session(mcp_servers: [ "digitalocean-tadasant" ])

    trigger = triggers(:enabled_slack_trigger)
    trigger.update!(reuse_session: true, last_session_id: session.id)
    assert_equal [ "slack-workspace" ], trigger.mcp_servers

    trigger.create_session!(prompt: "Follow-up")

    assert_equal [ "slack-workspace" ], session.reload.mcp_servers,
      "an explicit non-empty trigger server list is still authoritative for recurring triggers"
  end

  test "one-time reuse trigger that declares MCP servers still syncs them" do
    AgentSessionJob.stubs(:enqueue_with_prompt)

    session = build_reusable_session(mcp_servers: [ "digitalocean-tadasant" ])
    watched = Session.create!(
      prompt: "Watched downstream session",
      git_root: "https://github.com/test/repo",
      branch: "main"
    )
    # POST /api/v1/triggers permits mcp_servers, so a one-time reuse trigger CAN
    # legitimately carry a non-empty list. Skipping sync for every one-time
    # trigger would silently ignore it.
    trigger = Trigger.create!(
      name: "One-time reuse trigger with servers",
      status: "enabled",
      agent_root_name: "agent-orchestrator",
      prompt_template: "go",
      reuse_session: true,
      last_session_id: session.id,
      mcp_servers: [ "slack-workspace" ],
      trigger_conditions_attributes: [
        {
          condition_type: "ao_event",
          configuration: { "event_name" => "session_needs_input", "watched_session_id" => watched.id }
        }
      ]
    ).reload
    assert trigger.one_time_reuse_trigger?

    trigger.create_session!(prompt: "go")

    assert_equal [ "slack-workspace" ], session.reload.mcp_servers,
      "a one-time trigger that explicitly declares servers is still authoritative for them"
  end

  test "syncing a narrower MCP server list onto a session logs at warn" do
    AgentSessionJob.stubs(:enqueue_with_prompt)

    session = build_reusable_session(mcp_servers: [ "slack-workspace", "digitalocean-tadasant" ])
    trigger = triggers(:enabled_slack_trigger)
    trigger.update!(reuse_session: true, last_session_id: session.id)

    Rails.logger.expects(:warn).at_least_once.with { |msg| msg.to_s.include?("digitalocean-tadasant") }

    trigger.create_session!(prompt: "Follow-up")
  end
end
