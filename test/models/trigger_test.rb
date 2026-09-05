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

  # === Failed status (issue #76) ===

  test "failed is a valid status distinct from disabled" do
    @trigger.status = "failed"
    assert @trigger.valid?
    assert @trigger.failed?
    assert_not @trigger.enabled?
    assert_not @trigger.disabled?
  end

  test "mark_failed parks the trigger with the error instead of destroying it" do
    assert @trigger.mark_failed(StandardError.new("agent root not found"))

    @trigger.reload
    assert @trigger.failed?
    assert_not_nil @trigger.failed_at
    assert_equal "StandardError: agent root not found", @trigger.last_error
  end

  test "mark_failed accepts a plain string and bounds what it stores" do
    @trigger.mark_failed("x" * (Trigger::MAX_LAST_ERROR_CHARS + 500))

    assert_equal Trigger::MAX_LAST_ERROR_CHARS, @trigger.reload.last_error.length
  end

  test "mark_failed persists even when the trigger would not pass validation" do
    # A concurrent sibling-wake cleanup can cascade-delete the conditions out from
    # under an in-memory trigger, which `validates :trigger_conditions, presence:`
    # would then reject. Recording the failure must not be what loses to that race.
    @trigger.trigger_conditions.destroy_all
    @trigger.trigger_conditions.reload

    assert_not @trigger.valid?, "precondition: a conditionless trigger is invalid"
    assert @trigger.mark_failed(StandardError.new("boom"))
    assert_equal "failed", @trigger.reload.status
  end

  test "failed scope selects parked triggers" do
    @trigger.mark_failed(StandardError.new("boom"))

    assert_includes Trigger.failed, @trigger
    assert_not_includes Trigger.enabled, @trigger
    assert_not_includes Trigger.disabled, @trigger
  end

  test "enable! re-arms a failed trigger by clearing the failure state" do
    @trigger.mark_failed(StandardError.new("boom"))
    @trigger.reload

    @trigger.enable!

    assert @trigger.enabled?
    assert_nil @trigger.failed_at
    assert_nil @trigger.last_error
  end

  test "toggle! on a failed trigger re-arms it rather than disabling it" do
    @trigger.mark_failed(StandardError.new("boom"))
    @trigger.reload

    @trigger.toggle!

    assert @trigger.enabled?, "a failed trigger toggles back into service, not into disabled"
    assert_nil @trigger.last_error
  end

  # The API serializes failed_at/last_error unconditionally and the UI renders
  # them, so a trigger that recovered by ANY route — not just #enable! — must
  # stop advertising the failure. The edit form and action_trigger's update both
  # write status directly.
  test "any write that moves the status off failed clears the failure fields" do
    %w[enabled disabled].each do |recovered_status|
      @trigger.mark_failed(StandardError.new("boom"))
      @trigger.reload
      assert_not_nil @trigger.last_error, "precondition for #{recovered_status}"

      @trigger.update!(status: recovered_status)

      assert_nil @trigger.reload.failed_at, "failed_at should be cleared on -> #{recovered_status}"
      assert_nil @trigger.last_error, "last_error should be cleared on -> #{recovered_status}"
    end
  end

  test "a write that does not touch the status leaves the failure fields alone" do
    @trigger.mark_failed(StandardError.new("boom"))
    @trigger.reload

    @trigger.update!(name: "Renamed while parked")

    assert @trigger.reload.failed?
    assert_not_nil @trigger.failed_at
    assert_equal "StandardError: boom", @trigger.last_error
  end

  test "spent_one_shot_wake? is true only once the one-time schedule is consumed" do
    trigger = triggers(:one_time_schedule_trigger)
    condition = trigger.trigger_conditions.first
    condition.update!(last_triggered_at: nil)

    assert_not trigger.reload.spent_one_shot_wake?, "an unconsumed schedule re-arms"

    # A raise from the cleanup that follows a successful fire lands with the
    # schedule already spent — re-arming would deliver nothing.
    condition.update!(last_triggered_at: Time.current)
    assert trigger.reload.spent_one_shot_wake?
  end

  test "spent_one_shot_wake? is false for a trigger with no one-time schedule" do
    assert_not @trigger.spent_one_shot_wake?,
      "a recurring trigger really does go back into service when re-enabled"
  end

  # === Tests for dead_one_time_wake? ===

  def wake_trigger(conditions_attributes, sessions_created_count: 0)
    requester = Session.create!(
      prompt: "Requester",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo",
      branch: "main",
      status: :waiting
    )
    Trigger.create!(
      name: "Wake",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "wake up",
      reuse_session: true,
      last_session_id: requester.id,
      sessions_created_count: sessions_created_count,
      trigger_conditions_attributes: conditions_attributes
    )
  end

  test "dead_one_time_wake? is true once a pending one-time schedule wake is consumed" do
    trigger = wake_trigger([
      { condition_type: "schedule", configuration: { "scheduled_at" => 12.hours.from_now.iso8601, "timezone" => "UTC" } }
    ])

    assert_not trigger.dead_one_time_wake?, "an armed wake is not dead"

    trigger.trigger_conditions.first.update!(last_triggered_at: Time.current)

    assert trigger.reload.dead_one_time_wake?,
      "a consumed one-time schedule can never fire again, whatever its scheduled_at says"
  end

  test "dead_one_time_wake? is false when the trigger also carries a live condition" do
    trigger = wake_trigger([
      { condition_type: "schedule", configuration: { "scheduled_at" => 12.hours.from_now.iso8601, "timezone" => "UTC" } },
      { condition_type: "schedule", configuration: { "unit" => "hours", "interval" => 1, "timezone" => "UTC" } }
    ])
    trigger.trigger_conditions.detect(&:one_time_schedule?).update!(last_triggered_at: Time.current)

    assert_not trigger.reload.dead_one_time_wake?,
      "the recurring condition keeps the trigger legitimate"
  end

  test "dead_one_time_wake? is false when the wake created a session" do
    trigger = wake_trigger(
      [ { condition_type: "schedule", configuration: { "scheduled_at" => 12.hours.from_now.iso8601, "timezone" => "UTC" } } ],
      sessions_created_count: 1
    )
    trigger.trigger_conditions.first.update!(last_triggered_at: Time.current)

    assert_not trigger.reload.dead_one_time_wake?,
      "a wake that spawned a session is the firing job's residue, not a consumed wake"
  end

  test "dead_one_time_wake? is false for a trigger with no one-shot condition" do
    # A recurring reuse trigger, consumed and having created nothing: it clears
    # every clause except `one_time_reuse_trigger?`, so the predicate must key on
    # that one and not fall through on the other two.
    trigger = wake_trigger([
      { condition_type: "schedule", configuration: { "unit" => "hours", "interval" => 1, "timezone" => "UTC" } }
    ])
    trigger.trigger_conditions.first.update!(last_triggered_at: Time.current)

    assert_not trigger.reload.dead_one_time_wake?,
      "a recurring schedule goes back into service; it is never dead"
    assert_not @trigger.dead_one_time_wake?, "nor is a Slack trigger"
  end

  # The predicate answers for BOTH one-shot shapes, because
  # cancel_pending_one_time_wake_triggers consumes both. CleanupStaleTriggersJob
  # only asks it of triggers carrying a one-time schedule, so this shape answers
  # true and is still not collected — tadasant/zimmer#793.
  test "dead_one_time_wake? is true for a consumed session-scoped ao_event wake" do
    watched = Session.create!(
      prompt: "Watched",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo",
      branch: "main",
      status: :running
    )
    trigger = wake_trigger([
      { condition_type: "ao_event", configuration: { "event_name" => "session_needs_input", "watched_session_id" => watched.id } }
    ])

    assert_not trigger.dead_one_time_wake?, "an armed watcher is not dead"

    trigger.trigger_conditions.first.update!(last_triggered_at: Time.current)

    assert trigger.reload.dead_one_time_wake?,
      "a consumed session-scoped ao_event is spent for good — AoEventTriggerJob skips it forever"
  end

  # A failed sibling is the record of a wake that TRIED and could not. Sweeping
  # it up as a side effect of a later sibling firing successfully is the same
  # silent loss the parking exists to prevent.
  test "hold_wake_group! leaves a failed sibling unmarked" do
    requester = Session.create!(
      prompt: "Requester",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo",
      status: :needs_input,
      metadata: {}
    )
    watched = Session.create!(
      prompt: "Watched",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo",
      status: :running,
      metadata: {}
    )

    build_wake = lambda do |name, event_name|
      Trigger.create!(
        name: name,
        status: "enabled",
        agent_root_name: "zimmer",
        prompt_template: "go {{event}}",
        reuse_session: true,
        last_session_id: requester.id,
        trigger_conditions_attributes: [
          { condition_type: "ao_event", configuration: { "event_name" => event_name, "watched_session_id" => watched.id } }
        ]
      )
    end

    firing = build_wake.call("Firing wake", "session_archived")
    healthy_sibling = build_wake.call("Healthy sibling", "session_needs_input")
    failed_sibling = build_wake.call("Failed sibling", "session_failed")
    failed_sibling.mark_failed(StandardError.new("agent root not found"))

    assert_equal 1, firing.hold_wake_group!, "only the healthy sibling is spoken for"

    assert_not_nil healthy_sibling.reload.wake_held_at
    assert_nil failed_sibling.reload.wake_held_at,
      "a failed sibling carries evidence and is not the woken turn's to retire"
    assert_equal "failed", failed_sibling.status
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
    AgentSessionJob.expects(:enqueue_with_prompt).with(session.id, "Follow-up prompt", images: nil, files: nil).once

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

  # MCP server validations. `mcp_servers` is checked at save exactly as
  # catalog_skills/hooks/plugins are; before zimmer#506 it was the one artifact
  # kind a trigger could name wrongly and only find out about when it fired.
  test "mcp_servers must be an array" do
    @trigger.mcp_servers = "not_an_array"
    assert_not @trigger.valid?
    assert_includes @trigger.errors[:mcp_servers], "must be an array"
  end

  test "mcp_servers validates server names exist in catalog" do
    ServersConfig.stubs(:exists?).with("valid-server").returns(true)
    ServersConfig.stubs(:exists?).with("nonexistent-server").returns(false)
    @trigger.mcp_servers = [ "valid-server", "nonexistent-server" ]
    assert_not @trigger.valid?
    assert @trigger.errors[:mcp_servers].any? { |e| e.include?("nonexistent-server") }
  end

  test "mcp_servers accepts valid server names" do
    ServersConfig.stubs(:exists?).returns(true)
    @trigger.mcp_servers = [ "some-server" ]
    @trigger.valid?
    assert_empty @trigger.errors[:mcp_servers]
  end

  test "mcp_servers accepts empty array" do
    @trigger.mcp_servers = []
    @trigger.valid?
    assert_empty @trigger.errors[:mcp_servers]
  end

  test "a trigger already holding a stale MCP server name still saves when the change is elsewhere" do
    # `mcp_servers` is `default: [], null: false`, so rows predate this
    # validation. An edit that does not touch the column must not be blocked by
    # a name that went stale under it — the fire-time heal is what cleans it up.
    @trigger.update_column(:mcp_servers, [ "gone-server" ])
    @trigger.reload
    ServersConfig.stubs(:exists?).with("gone-server").returns(false)

    assert @trigger.update(name: "Renamed trigger"), @trigger.errors.full_messages.to_sentence
    assert_equal [ "gone-server" ], @trigger.reload.mcp_servers
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

    # Archive the session. It carries a Claude session_id, so it has a
    # transcript to restore and is a genuine resuscitation candidate.
    session.update_columns(session_id: SecureRandom.uuid, status: Session.statuses[:archived])

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

    # Archive the session. It ran (it has a session_id), so this is a genuine
    # resuscitation candidate and a service failure must still surface.
    session.update_columns(session_id: SecureRandom.uuid, status: Session.statuses[:archived])

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

  # Trigger-wiring coverage for GitHub issue pulsemcp/pulsemcp#4600.
  #
  # This exercises how create_session! HANDLES the resuscitation race outcome:
  # when UnarchiveSessionService reports the target session as an already-active
  # idempotent success (because a concurrent winner unarchived it and its job
  # advanced the row to running), create_session! must NOT raise in
  # resuscitate_session! and must proceed to follow_up_session! — reusing the
  # session and enqueuing the prompt.
  #
  # The service's OWN race handling — returning success rather than a failure for
  # an already-advanced winner — is what the pulsemcp/pulsemcp#4600 fix changed, and it is covered
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
    session.update_columns(session_id: SecureRandom.uuid, status: Session.statuses[:archived])

    # ...but the winning fire has already unarchived it and its job advanced the
    # row to running with archived_at cleared. Model that observable effect by
    # advancing the row when the (stubbed) service is invoked, and returning the
    # benign success Result the real service produces for this race (pulsemcp/pulsemcp#4600). The
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

  # Regression for the "Daily Fleet Cleanup" incident (2026-08-23).
  #
  # A recurring trigger's reuse candidate was a `spot` session that was held at
  # the starting line for a whole quota window, never ran a single turn, and was
  # then archived. It had no Claude session_id, so UnarchiveSessionService
  # refused it ("Session has no session_id") and #resuscitate_session! raised.
  # ScheduleTriggerJob advanced last_triggered_at to stop the retry loop, so the
  # sweep created nothing — that day, and every day after, because the reuse
  # candidate never changed.
  test "create_session! spawns a fresh session when the archived reuse candidate never ran" do
    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo",
      default_branch: "main",
      subdirectory: nil
    )
    AgentRootsConfig.stubs(:find!).with(@trigger.agent_root_name).returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    session = @trigger.create_session!(prompt: "Initial")
    @trigger.update!(reuse_session: true, resuscitate_archived: true, last_session_id: session.id)

    # Never took a turn (no session_id), then archived — exactly session 7456.
    assert_nil session.session_id
    session.update_column(:status, Session.statuses[:archived])

    # The unarchive path is not even attempted. UnarchiveSessionService restores
    # such a session now rather than refusing it (zimmer#557), but restoring it
    # here would not do what the trigger asked: a follow-up into a session with
    # no session_id is reclassified as a fresh start that runs the session's OWN
    # prompt, silently dropping this fire's. Spawning is what the trigger meant.
    UnarchiveSessionService.expects(:call).never

    fresh = nil
    assert_difference("Session.count", 1) do
      assert_nothing_raised do
        fresh = @trigger.create_session!(prompt: "Daily sweep")
      end
    end
    assert_not_equal session.id, fresh.id

    # And the trigger heals itself on this same fire: the next run reuses the
    # fresh session rather than tripping over the archived one again.
    assert_equal fresh.id, @trigger.reload.last_session_id
  end

  # The self-perpetuating half of the same incident: without the fix, every
  # subsequent fire raised on the identical un-resuscitatable candidate.
  test "create_session! keeps firing on later runs after a never-ran reuse candidate" do
    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo",
      default_branch: "main",
      subdirectory: nil
    )
    AgentRootsConfig.stubs(:find!).with(@trigger.agent_root_name).returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)
    AgentSessionJob.stubs(:enqueue_with_prompt)

    session = @trigger.create_session!(prompt: "Initial")
    @trigger.update!(reuse_session: true, resuscitate_archived: true, last_session_id: session.id)
    session.update_column(:status, Session.statuses[:archived])

    fresh = nil
    assert_difference("Session.count", 1) do
      fresh = @trigger.create_session!(prompt: "Day one")
    end

    # Day two: the fresh session is alive, so it is reused as normal and the
    # prompt is actually delivered into it.
    fresh.update_column(:status, Session.statuses[:needs_input])
    assert_no_difference("Session.count") do
      reused = @trigger.create_session!(prompt: "Day two")
      assert_equal fresh.id, reused.id
    end
    assert_equal :delivered, @trigger.last_follow_up_status
  end

  # The other side of the screen. A runtime that mints its own conversation id
  # (codex) has that id cleared by
  # ProcessLifecycleManager#release_stale_runtime_session_id! on a fresh-start
  # recovery, so a session that ran for hours can be archived holding a full
  # transcript and no session_id. That session is NOT never-run: it has work, so
  # UnarchiveSessionService still tries to resume it and still cannot — and that
  # IS a failure a human should see, not a session to abandon and silently
  # duplicate.
  test "create_session! still raises for an archived session with a transcript but no session_id" do
    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo",
      default_branch: "main",
      subdirectory: nil
    )
    AgentRootsConfig.stubs(:find!).with(@trigger.agent_root_name).returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    session = @trigger.create_session!(prompt: "Initial")
    @trigger.update!(reuse_session: true, resuscitate_archived: true, last_session_id: session.id)

    session.update_columns(
      session_id: nil,
      transcript: %({"type":"user","message":{"role":"user","content":"hours of work"}}\n),
      status: Session.statuses[:archived]
    )

    UnarchiveSessionService.stubs(:call).with(session: session).returns(
      UnarchiveSessionService::Result.new(success?: false, error: "Session has no session_id")
    )

    error = nil
    assert_no_difference("Session.count") do
      error = assert_raises(RuntimeError) { @trigger.create_session!(prompt: "Should surface") }
    end
    assert_match(/Failed to resuscitate archived session/, error.message)
  end

  # A one-time reuse trigger ("wake session 7456 at 9am") means THAT session, so
  # an un-resuscitatable target is still a silent skip — spawning a fresh session
  # would deliver the wake to an agent that knows nothing about the work.
  test "create_session! skips a one-time reuse trigger whose archived target never ran" do
    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo",
      default_branch: "main",
      subdirectory: nil
    )
    AgentRootsConfig.stubs(:find!).with(@trigger.agent_root_name).returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    session = @trigger.create_session!(prompt: "Initial")
    @trigger.trigger_conditions.destroy_all
    @trigger.trigger_conditions.create!(
      condition_type: "schedule",
      configuration: { "scheduled_at" => 5.minutes.from_now.iso8601 }
    )
    @trigger.update!(reuse_session: true, resuscitate_archived: true, last_session_id: session.id)
    session.update_column(:status, Session.statuses[:archived])

    assert @trigger.reload.one_time_reuse_trigger?
    UnarchiveSessionService.expects(:call).never

    assert_no_difference("Session.count") do
      assert_nothing_raised { @trigger.create_session!(prompt: "Wake up") }
    end
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

  # Fire-time reconciliation of the catalog-artifact columns.
  #
  # The policy these pin, in one line: the SESSION never receives a name the
  # catalog cannot resolve, and the TRIGGER never loses one (zimmer#853).
  test "create_session! spawns with the resolvable MCP servers and leaves the trigger's list alone" do
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

    # ...and the trigger should still name both, so the stale one can be remapped
    @trigger.reload
    assert_equal [ "valid-server", "stale-server" ], @trigger.mcp_servers
    assert_equal({ "stale-server" => @trigger.unresolved_catalog_references["mcp_servers"]["stale-server"] },
      @trigger.unresolved_catalog_references["mcp_servers"])
  end

  test "create_session! spawns with an empty server list when none of them resolve" do
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

    # The trigger still fires — losing every server degrades the session, it
    # does not brick the trigger (zimmer#207, zimmer#834).
    assert session.persisted?
    assert_equal [], session.mcp_servers

    # Nothing was taken off the trigger
    @trigger.reload
    assert_equal [ "stale-a", "stale-b" ], @trigger.mcp_servers
    assert_equal %w[stale-a stale-b], @trigger.unresolved_catalog_references["mcp_servers"].keys.sort
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

  # The empty-catalog guard is load-bearing (zimmer#112): a failed `air resolve`
  # degrades every config facade to [], and without it healing would read that
  # as "every reference is stale" and strip all four columns on every trigger.
  test "heal_catalog_references! removes nothing when the catalogs resolve empty" do
    @trigger.update_column(:mcp_servers, [ "server-a" ])
    @trigger.update_column(:catalog_skills, [ "skill-a" ])
    @trigger.update_column(:catalog_hooks, [ "hook-a" ])
    @trigger.update_column(:catalog_plugins, [ "plugin-a" ])

    [ ServersConfig, SkillsConfig, HooksConfig, PluginsConfig ].each do |config|
      config.stubs(:all).returns([])
      config.stubs(:exists?).returns(false)
    end

    AlertService.expects(:raise_alert).never

    resolvable = @trigger.heal_catalog_references!

    @trigger.reload
    assert_equal [ "server-a" ], @trigger.mcp_servers
    assert_equal [ "skill-a" ], @trigger.catalog_skills
    assert_equal [ "hook-a" ], @trigger.catalog_hooks
    assert_equal [ "plugin-a" ], @trigger.catalog_plugins

    # Nor is a deployment-wide catalog outage written down as per-row state...
    assert_equal({}, @trigger.unresolved_catalog_references)
    # ...and the fire is handed the column untouched rather than an empty list,
    # so a spawn fails loudly on it instead of quietly dropping every server.
    assert_equal [ "server-a" ], resolvable[:mcp_servers]
    assert_equal [ "server-a" ], @trigger.resolvable_mcp_servers
  end

  test "heal_catalog_references! filters the unresolvable entry once the catalog resolves again" do
    # The positive control for the guard above: same trigger, same stale names,
    # a catalog that actually loaded. The entry is filtered OUT of what a fire
    # would spawn with, and left ON the row.
    @trigger.update_column(:mcp_servers, [ "server-a", "gone-server" ])
    ServersConfig.stubs(:all).returns([ OpenStruct.new(name: "server-a") ])
    ServersConfig.stubs(:exists?).with("server-a").returns(true)
    ServersConfig.stubs(:exists?).with("gone-server").returns(false)
    AlertService.stubs(:raise_alert)

    resolvable = @trigger.heal_catalog_references!

    assert_equal [ "server-a" ], resolvable[:mcp_servers]
    assert_equal [ "server-a", "gone-server" ], @trigger.reload.mcp_servers
    assert_equal [ "gone-server" ], @trigger.unresolved_catalog_references["mcp_servers"].keys
  end

  # The bookkeeping column exists for exactly this: preserving the reference
  # without it would turn one alert into one per fire, forever.
  test "an unresolvable reference is announced once, not on every fire" do
    @trigger.update_column(:mcp_servers, [ "keeper", "gone-server" ])
    ServersConfig.stubs(:exists?).with("keeper").returns(true)
    ServersConfig.stubs(:exists?).with("gone-server").returns(false)

    AlertService.expects(:raise_alert).once

    3.times { @trigger.heal_catalog_references! }

    assert_equal [ "keeper", "gone-server" ], @trigger.reload.mcp_servers
  end

  test "a second reference going unresolvable is announced even though the first already was" do
    @trigger.update_column(:mcp_servers, [ "gone-a", "still-here" ])
    ServersConfig.stubs(:exists?).with("gone-a").returns(false)
    ServersConfig.stubs(:exists?).with("still-here").returns(true)

    AlertService.expects(:raise_alert).twice

    @trigger.heal_catalog_references!

    # `still-here` now goes too — a second rename, days later.
    ServersConfig.stubs(:exists?).with("still-here").returns(false)
    @trigger.heal_catalog_references!

    assert_equal %w[gone-a still-here], @trigger.reload.unresolved_catalog_references["mcp_servers"].keys.sort
  end

  # The other half of "kept, not deleted": the moment the catalog carries the
  # name again — a reverted rename, a re-added artifact — the trigger is whole
  # again with no edit, and a later disappearance announces afresh.
  test "the bookkeeping clears when a reference resolves again, so a later loss announces again" do
    @trigger.update_column(:mcp_servers, [ "flapper" ])
    ServersConfig.stubs(:exists?).with("flapper").returns(false)
    AlertService.expects(:raise_alert).twice

    @trigger.heal_catalog_references!
    assert_equal [ "flapper" ], @trigger.reload.unresolved_catalog_references["mcp_servers"].keys

    ServersConfig.stubs(:exists?).with("flapper").returns(true)
    resolvable = @trigger.heal_catalog_references!
    assert_equal [ "flapper" ], resolvable[:mcp_servers], "the reference works again with no edit at all"
    assert_equal({}, @trigger.reload.unresolved_catalog_references)

    ServersConfig.stubs(:exists?).with("flapper").returns(false)
    @trigger.heal_catalog_references!
  end

  # A degraded resolve serves a last-known-good tree that can predate a rename,
  # so a name that is valid today can look unresolvable to this fire. Same call
  # AirPrepareService#persist_scrubbed_catalog_skills makes.
  test "a degraded catalog neither announces nor records, but still filters" do
    @trigger.update_column(:mcp_servers, [ "keeper", "maybe-gone" ])
    ServersConfig.stubs(:exists?).with("keeper").returns(true)
    ServersConfig.stubs(:exists?).with("maybe-gone").returns(false)
    AirCatalogService.stubs(:degraded?).returns(true)

    AlertService.expects(:raise_alert).never

    resolvable = @trigger.heal_catalog_references!

    assert_equal [ "keeper" ], resolvable[:mcp_servers]
    assert_equal({}, @trigger.reload.unresolved_catalog_references)
    assert_equal [ "keeper", "maybe-gone" ], @trigger.mcp_servers
  end

  test "the bookkeeping drops a name the operator has taken off the trigger" do
    @trigger.update_column(:mcp_servers, [ "gone-server" ])
    ServersConfig.stubs(:exists?).with("gone-server").returns(false)
    AlertService.stubs(:raise_alert)

    @trigger.heal_catalog_references!
    assert_equal [ "gone-server" ], @trigger.reload.unresolved_catalog_references["mcp_servers"].keys

    @trigger.update_column(:mcp_servers, [])
    @trigger.heal_catalog_references!

    assert_equal({}, @trigger.reload.unresolved_catalog_references)
  end

  test "the unresolvable MCP server alert states its wording, source and dedup key" do
    @trigger.update_column(:mcp_servers, [ "keeper", "gone-server" ])
    ServersConfig.stubs(:exists?).with("keeper").returns(true)
    ServersConfig.stubs(:exists?).with("gone-server").returns(false)

    AlertService.expects(:raise_alert).with do |message, options|
      assert_equal "Trigger degraded: MCP server(s) missing from the catalog", message
      assert_equal "Trigger#create_session!", options[:source]
      assert_equal "trigger_stale_mcp_#{@trigger.id}", options[:dedup_key]
      assert_includes options[:details], "Trigger *#{@trigger.name}* (ID: #{@trigger.id})"
      assert_includes options[:details], "• Unresolvable: gone-server"
      assert_includes options[:details], "• Still resolving: keeper"
      # The words that matter: an operator has to know the name is still there
      # to remap, and which of the two repairs is theirs to choose.
      assert_includes options[:details], "KEPT on the trigger — nothing has been deleted"
      assert_includes options[:details], "If the server was RENAMED"
      assert_includes options[:details], "/triggers/#{@trigger.id}|View trigger in Zimmer>"
      true
    end.once

    @trigger.heal_catalog_references!
  end

  test "the hook and plugin alerts keep their derived titles and dedup keys" do
    # `dedup_noun` for these two is derived from the noun rather than declared,
    # and nothing else in the suite pins the strings it produces.
    @trigger.update_column(:catalog_hooks, [ "gone-hook" ])
    @trigger.update_column(:catalog_plugins, [ "gone-plugin" ])
    HooksConfig.stubs(:exists?).with("gone-hook").returns(false)
    PluginsConfig.stubs(:exists?).with("gone-plugin").returns(false)

    raised = []
    AlertService.stubs(:raise_alert).with do |message, options|
      raised << [ message, options[:source], options[:dedup_key] ]
      true
    end

    @trigger.heal_catalog_references!

    assert_includes raised, [
      "Trigger degraded: catalog hook(s) missing from the catalog",
      "Trigger#create_session!",
      "trigger_stale_hooks_#{@trigger.id}"
    ]
    assert_includes raised, [
      "Trigger degraded: catalog plugin(s) missing from the catalog",
      "Trigger#create_session!",
      "trigger_stale_plugins_#{@trigger.id}"
    ]
    # Every kind is preserved, not only MCP servers — the policy lives in the
    # concern, so it is the same policy for all four declarations.
    assert_equal [ "gone-hook" ], @trigger.reload.catalog_hooks
    assert_equal [ "gone-plugin" ], @trigger.catalog_plugins
    assert_equal [ "gone-hook" ], @trigger.unresolved_catalog_references["catalog_hooks"].keys
    assert_equal [ "gone-plugin" ], @trigger.unresolved_catalog_references["catalog_plugins"].keys
  end

  test "create_session! raises an alert when an MCP server stops resolving" do
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
      "Trigger degraded: MCP server(s) missing from the catalog",
      has_entries(
        source: "Trigger#create_session!",
        dedup_key: "trigger_stale_mcp_#{@trigger.id}"
      )
    ).once

    @trigger.create_session!(prompt: "Test prompt")
  end

  test "create_session! does not rewrite the trigger's MCP servers, and records what it could not resolve" do
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

    # Fresh load, not in-memory: the configuration column is untouched and the
    # sidecar carries the two names with a first-seen timestamp each.
    db_trigger = Trigger.find(@trigger.id)
    assert_equal [ "keeper", "removed-1", "removed-2" ], db_trigger.mcp_servers
    recorded = db_trigger.unresolved_catalog_references["mcp_servers"]
    assert_equal %w[removed-1 removed-2], recorded.keys.sort
    recorded.each_value { |seen_at| assert_not_nil Time.iso8601(seen_at) }
  end

  # === zimmer#853 — the reproduction ===
  #
  # A catalog RENAME is what this path meets most often, and it arrives looking
  # exactly like a deletion: the old slug simply stops resolving. Destroying the
  # name on that reading makes the rename unrecoverable from the trigger's side.
  test "create_session! keeps an unresolvable MCP server on the trigger and spawns without it" do
    mock_agent_root = OpenStruct.new(url: "https://github.com/test/repo", default_branch: "main", subdirectory: nil)
    AgentRootsConfig.stubs(:find!).with(@trigger.agent_root_name).returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)
    AlertService.stubs(:raise_alert)

    # `slack-workspace` was renamed to `slack-zimmer` in the catalog on 2026-09-03.
    ServersConfig.stubs(:exists?).with("keeper").returns(true)
    ServersConfig.stubs(:exists?).with("slack-workspace").returns(false)
    @trigger.update_column(:mcp_servers, [ "keeper", "slack-workspace" ])

    session = @trigger.create_session!(prompt: "Test prompt")

    assert_equal [ "keeper" ], session.mcp_servers,
      "the spawned session must not carry a name the catalog cannot resolve"
    assert_equal [ "keeper", "slack-workspace" ], @trigger.reload.mcp_servers,
      "the trigger must still name the renamed server, or nothing can remap it afterwards"
  end

  # The reuse path syncs all four columns onto the session it follows up into,
  # so it has to filter too — otherwise a reuse would push an unresolvable name
  # onto a live session that the spawn path would have refused to hand it.
  test "a reuse fire syncs only the resolvable MCP servers onto the session" do
    mock_agent_root = OpenStruct.new(url: "https://github.com/test/repo", default_branch: "main", subdirectory: nil)
    AgentRootsConfig.stubs(:find!).with(@trigger.agent_root_name).returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)
    AgentSessionJob.stubs(:enqueue_with_prompt)
    AlertService.stubs(:raise_alert)

    session = @trigger.create_session!(prompt: "First")
    session.update_column(:status, Session.statuses[:needs_input])
    @trigger.update!(reuse_session: true, last_session_id: session.id)

    ServersConfig.stubs(:exists?).with("keeper").returns(true)
    ServersConfig.stubs(:exists?).with("slack-workspace").returns(false)
    @trigger.update_column(:mcp_servers, [ "keeper", "slack-workspace" ])

    @trigger.create_session!(prompt: "Second")

    assert_equal [ "keeper" ], session.reload.mcp_servers
    assert_equal [ "keeper", "slack-workspace" ], @trigger.reload.mcp_servers
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

  test "create_session! reuses its session without resolving an unknown agent root" do
    # Regression for https://github.com/tadasant/zimmer/issues/600. A reuse fire
    # never hands `agent_root_name` to Session.create_from_agent_root!, so a name
    # that is not in the catalog must not stop it. Before the raise moved to the
    # spawn path this raised, ScheduleTriggerJob parked the trigger `failed`, and
    # the target session — every per-session wake has exactly this shape — slept
    # forever.
    target = sessions(:needs_input)
    trigger = wake_trigger_for(target, agent_root_name: "claude_code")

    AgentRootsConfig.stubs(:exists?).with("claude_code").returns(false)
    AgentSessionJob.stubs(:enqueue_with_prompt).returns(OpenStruct.new(job_id: "job-600"))
    AlertService.expects(:raise_alert).never

    session = assert_no_difference "Session.count" do
      trigger.create_session!(prompt: "Resume")
    end

    assert_equal target.id, session&.id, "the wake should have reused its target session"
    assert_equal :delivered, trigger.last_follow_up_status
    assert_equal "claude_code", trigger.reload.agent_root_name,
      "there is no successor to repoint to, and a reuse fire has no reason to object"
  end

  test "create_session! still repoints a RENAMED agent root on a fire that only reuses" do
    # The non-raising half of the heal stays on every fire. `agent_root_name` is
    # read off the fire path — Mcp::Tools::SearchTriggers and
    # Mcp::Tools::ActionTrigger gate a scope-restricted connection on it — so a
    # reuse trigger that never spawns must not keep a vanished name forever.
    git_url = "https://github.com/test/repo"
    target = sessions(:needs_input)
    target.update!(git_root: git_url, subdirectory: nil)
    trigger = wake_trigger_for(target, agent_root_name: "old-root")

    AgentRootsConfig.stubs(:exists?).with("old-root").returns(false)
    successor = OpenStruct.new(name: "new-root", url: git_url, default_branch: "main", subdirectory: nil)
    AgentRootsConfig.stubs(:all).returns([ successor ])
    AgentSessionJob.stubs(:enqueue_with_prompt).returns(OpenStruct.new(job_id: "job-600"))

    session = trigger.create_session!(prompt: "Resume")

    assert_equal target.id, session&.id
    assert_equal "new-root", trigger.reload.agent_root_name
  end

  test "create_session! still raises on an unhealable agent root when a reuse trigger falls through to spawn" do
    # The other half of #600: deferring the raise must not make it unreachable. A
    # recurring reuse trigger whose target is no longer reusable passes THROUGH
    # the reuse block and out the bottom to the spawn path, which does hand the
    # name to Session.create_from_agent_root!, so the raise still has to fire.
    stranded = sessions(:archived)
    trigger = Trigger.create!(
      name: "Recurring reuse trigger whose target went to trash",
      agent_root_name: "gone-root",
      prompt_template: "Check in",
      reuse_session: true,
      resuscitate_archived: false,
      trigger_conditions_attributes: [
        {
          condition_type: "slack",
          configuration: { "channel_id" => "C0A6BF8T45R", "channel_name" => "eng-ci", "event_type" => "new_message" }
        }
      ]
    )
    trigger.update_columns(last_session_id: stranded.id)

    AgentRootsConfig.stubs(:exists?).with("gone-root").returns(false)

    error = assert_no_difference "Session.count" do
      assert_raises(AgentRootsConfig::AgentRootNotFoundError) do
        trigger.reload.create_session!(prompt: "Check in")
      end
    end
    assert_match(/no successor could be identified/, error.message)
  end

  # Catalog skills: same policy, from the same concern.
  test "create_session! spawns with the resolvable catalog skills and keeps the rest on the trigger" do
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

    # Trigger keeps both names
    @trigger.reload
    assert_equal [ "valid-skill", "stale-skill" ], @trigger.catalog_skills

    # Session only gets the one the catalog resolves
    assert_equal [ "valid-skill" ], session.catalog_skills
  end

  test "create_session! alerts when a catalog skill stops resolving" do
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
      "Trigger degraded: catalog skill(s) missing from the catalog",
      has_entries(
        source: "Trigger#create_session!",
        dedup_key: "trigger_stale_skills_#{@trigger.id}"
      )
    ).once

    @trigger.create_session!(prompt: "Test prompt")
  end

  # Catalog hooks: same policy, from the same concern.
  test "create_session! spawns with the resolvable catalog hooks and keeps the rest on the trigger" do
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
    assert_equal [ "valid-hook", "stale-hook" ], @trigger.catalog_hooks
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

  # A human hitting Pause and an agent then arming its own wake is an ordinary
  # sequence, and it used to leave the session asleep forever:
  # #pause writes paused_by "user", and #reusable_session? refuses to deliver into
  # a session carrying it, so the wake this very trigger arms was dropped on
  # arrival. Arming a wake is the moment that marker stops being true.
  test "after_create clears a stale user-pause marker so its own wake can be delivered" do
    target = Session.create!(git_root: "https://github.com/test/repo", agent_runtime: "claude_code",
      branch: "main", status: :needs_input, metadata: { "paused_by" => "user" })

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
    assert_nil target.metadata["paused_by"]
    assert trigger.send(:reusable_session?, target), "the wake must be deliverable to the session it was armed on"
  end

  # The marker is cleared on every status the wake can be delivered to, not just
  # the one branch that sleeps immediately. A running session lands in `waiting`
  # later (via pending_sleep, or a human stopping the turn), and an already-waiting
  # one is dormant now — both would otherwise hold a wake that is dropped on
  # arrival.
  test "after_create clears a stale user-pause marker on a running target too" do
    target = Session.create!(git_root: "https://github.com/test/repo", agent_runtime: "claude_code",
      branch: "main", status: :running, metadata: { "paused_by" => "user" })

    Trigger.create!(
      name: "Per-session wake", status: "enabled", agent_root_name: "zimmer",
      prompt_template: "Wake up", reuse_session: true, last_session_id: target.id,
      trigger_conditions_attributes: [
        { condition_type: "schedule", configuration: { "scheduled_at" => 1.hour.from_now.iso8601, "timezone" => "UTC" } }
      ]
    )

    target.reload
    assert_equal "running", target.status
    assert_equal true, target.metadata["pending_sleep"]
    assert_nil target.metadata["paused_by"]
  end

  test "after_create clears a stale user-pause marker on an already-waiting target" do
    target = Session.create!(git_root: "https://github.com/test/repo", agent_runtime: "claude_code",
      branch: "main", status: :waiting, session_id: "cli-abc",
      metadata: { "paused_by" => "user" })

    trigger = Trigger.create!(
      name: "Per-session wake", status: "enabled", agent_root_name: "zimmer",
      prompt_template: "Wake up", reuse_session: true, last_session_id: target.id,
      trigger_conditions_attributes: [
        { condition_type: "schedule", configuration: { "scheduled_at" => 1.hour.from_now.iso8601, "timezone" => "UTC" } }
      ]
    )

    target.reload
    assert_nil target.metadata["paused_by"]
    assert trigger.send(:reusable_session?, target)
  end

  # A `failed` session cannot take the wake for reasons the marker has nothing to
  # do with, so the record of who stopped it is left intact.
  test "after_create leaves the marker on a session the wake could not reach anyway" do
    target = Session.create!(git_root: "https://github.com/test/repo", agent_runtime: "claude_code",
      branch: "main", status: :failed, metadata: { "paused_by" => "user" })

    Trigger.create!(
      name: "Per-session wake", status: "enabled", agent_root_name: "zimmer",
      prompt_template: "Wake up", reuse_session: true, last_session_id: target.id,
      trigger_conditions_attributes: [
        { condition_type: "schedule", configuration: { "scheduled_at" => 1.hour.from_now.iso8601, "timezone" => "UTC" } }
      ]
    )

    assert_equal "user", target.reload.metadata["paused_by"]
  end

  # Only "user" goes. `recovery` and `spot_quota` name sweeps that are still
  # responsible for the session, and a wake does not relieve them of it.
  test "after_create leaves a recovery pause marker alone" do
    target = Session.create!(git_root: "https://github.com/test/repo", agent_runtime: "claude_code",
      branch: "main", status: :needs_input, metadata: { "paused_by" => "recovery" })

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

    assert_equal "recovery", target.reload.metadata["paused_by"]
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

  # === Tests for hold_wake_group! ===

  test "hold_wake_group! holds the firing trigger and every sibling with the same last_session_id" do
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

    held = needs_input_wake.hold_wake_group!

    assert_equal 2, held
    # The point of tadasant/zimmer#569: the group is still THERE and still armed.
    # Holding only records who owes it a retirement.
    assert Trigger.exists?(failed_wake.id), "sibling failed_wake must survive the fire"
    assert Trigger.exists?(deadline.id), "the deadline backstop must survive the fire"
    assert_not_nil failed_wake.reload.wake_held_at
    assert_not_nil deadline.reload.wake_held_at
    assert_nil deadline.trigger_conditions.first.last_triggered_at,
      "a held backstop is unfired and can still fire"
    assert_not_nil needs_input_wake.reload.wake_held_at,
      "the firing trigger holds itself too — its unfired conditions are the rest of the wait"
  end

  test "hold_wake_group! does not hold triggers for a different requester" do
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

    held = wake_a.hold_wake_group!

    assert_equal 0, held
    assert_nil wake_b.reload.wake_held_at, "wake for a different requester must be left alone"
  end

  test "hold_wake_group! does not hold recurring triggers (not one_time_reuse_trigger?)" do
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

    held = one_time_wake.hold_wake_group!

    assert_equal 0, held
    assert_nil recurring_trigger.reload.wake_held_at, "broadcast/recurring trigger must be left alone"
  end

  test "hold_wake_group! is a no-op for triggers that aren't one-time-reuse" do
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

    # Recurring trigger should not hold anything when it "fires"
    @trigger.update!(reuse_session: true, last_session_id: requester.id)
    assert_not @trigger.one_time_reuse_trigger?

    held = @trigger.hold_wake_group!

    assert_equal 0, held
    assert_nil sibling.reload.wake_held_at, "siblings are not held when the caller is recurring"
    assert_nil @trigger.reload.wake_held_at
  end

  test "hold_wake_group! returns 0 when no last_session_id" do
    @trigger.update!(reuse_session: true, last_session_id: nil)
    assert_equal 0, @trigger.hold_wake_group!
  end

  # Self-healing stale catalog plugins tests
  test "create_session! spawns with the resolvable catalog plugins and keeps the rest on the trigger" do
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
    assert_equal [ "valid-plugin", "stale-plugin" ], @trigger.catalog_plugins
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

  # === Tests for the bookkeeping-write TOCTOU race (issue pulsemcp/pulsemcp#3919) ===
  #
  # Internal bookkeeping writes (last_triggered_at / last_session_id) must NOT
  # run create-time/presence validations. The requester coming to rest
  # concurrently runs #retire_held_wake_triggers, which destroys this trigger and
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
    # jobs hold the trigger), then simulate a concurrent retirement cascade
    # deleting this trigger's only condition.
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

    # Capture log output instead of setting a strict mocha expectation on the
    # global Rails.logger. Under the parallel suite BroadcastService's circuit
    # breaker can emit its own warn through the same shared logger from a
    # background thread; a strict `expects(:warn)` rejects that concurrent call
    # as an unexpected invocation and fails this test (issue #114). A substring
    # assertion over captured output proves our warn fired while tolerating any
    # unrelated warns that race it.
    log = capture_log_output do
      trigger.create_session!(prompt: "Follow-up")
    end

    assert_match(/digitalocean-tadasant/, log,
      "narrowing a reused session's MCP server list must warn about the removed server")
  end

  # Swap Rails.logger for a StringIO-backed logger for the duration of the block
  # and return everything written to it. Unlike a mocha expectation on the shared
  # logger, this is indifferent to concurrent writers, so a background-thread warn
  # cannot invalidate the assertion.
  def capture_log_output
    original_logger = Rails.logger
    buffer = StringIO.new
    Rails.logger = ActiveSupport::Logger.new(buffer)

    yield

    buffer.string
  ensure
    Rails.logger = original_logger
  end

  # ---------------------------------------------------------------------------
  # Burst control
  #
  # A Slack alerts channel received a burst of messages and the trigger watching
  # it spawned 50 sessions — one per message — which the operator trashed by
  # hand. max_sessions_per_minute bounds that: over the cap, the trigger spawns
  # ONE burst-notice session (linking what it did spawn) and then goes quiet for
  # the rest of the burst.
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

  def burst_notice_sessions_for(trigger)
    Session.where("metadata->>'trigger_id' = ?", trigger.id.to_s)
      .select { |s| s.metadata["burst_notice"] }
  end

  test "max_sessions_per_minute must be a positive integer when set" do
    @trigger.max_sessions_per_minute = 0
    assert_not @trigger.valid?
    assert_includes @trigger.errors[:max_sessions_per_minute], "must be greater than 0"

    @trigger.max_sessions_per_minute = -1
    assert_not @trigger.valid?

    @trigger.max_sessions_per_minute = 3
    assert @trigger.valid?

    @trigger.max_sessions_per_minute = nil
    assert @trigger.valid?, "a nil cap means unbounded and must stay valid"
  end

  test "burst control: a trigger under its limit spawns normally" do
    stub_session_creation
    @trigger.update!(max_sessions_per_minute: 3)

    assert_difference("Session.count", 2) do
      2.times { |i| assert_not_nil @trigger.create_session!(prompt: "Alert #{i}") }
    end

    assert_empty burst_notice_sessions_for(@trigger)
    assert_not @trigger.reload.bursting?
    assert_equal 2, @trigger.burst_window_count
  end

  test "burst control: N events in one window with a limit of 3 spawn exactly 3 sessions plus one burst notice" do
    stub_session_creation
    @trigger.update!(max_sessions_per_minute: 3)

    # 10 events arrive inside one window — as they would inside a single Slack poll tick.
    assert_difference("Session.count", 4) do
      10.times { |i| @trigger.create_session!(prompt: "Alert #{i}") }
    end

    notices = burst_notice_sessions_for(@trigger)
    assert_equal 1, notices.size

    spawned = Session.where("metadata->>'trigger_id' = ?", @trigger.id.to_s)
      .reject { |s| s.metadata["burst_notice"] }
    assert_equal 3, spawned.size

    # The notice links the sessions the operator now has to deal with.
    notice = notices.first
    spawned.each do |session|
      assert_includes notice.prompt, "/sessions/#{session.id}"
    end
    assert_match(/Burst detected/, notice.prompt)

    # The notice never becomes the reuse target, and the trigger is now bursting.
    @trigger.reload
    assert_not_equal notice.id, @trigger.last_session_id
    assert @trigger.bursting?
  end

  test "burst control: a continuing burst spawns zero further sessions and zero further notices" do
    stub_session_creation
    @trigger.update!(max_sessions_per_minute: 3)

    10.times { |i| @trigger.create_session!(prompt: "Alert #{i}") }
    assert_equal 4, Session.where("metadata->>'trigger_id' = ?", @trigger.id.to_s).count

    # The outage keeps producing alerts. Next poll tick, 30 seconds later.
    travel 30.seconds do
      assert_no_difference("Session.count") do
        20.times { |i| assert_nil @trigger.create_session!(prompt: "Continuing alert #{i}") }
      end
      assert @trigger.last_fire_burst_suppressed?
    end

    # And the tick after that, past the original window — still no second notice.
    travel 90.seconds do
      assert_no_difference("Session.count") do
        20.times { |i| assert_nil @trigger.create_session!(prompt: "Still going #{i}") }
      end
    end

    # Four minutes in, the outage is still going: still quiet, still one notice.
    travel 4.minutes do
      assert_no_difference("Session.count") do
        20.times { |i| assert_nil @trigger.create_session!(prompt: "Hour-long outage #{i}") }
      end
    end

    assert_equal 1, burst_notice_sessions_for(@trigger).size
    assert_equal 4, Session.where("metadata->>'trigger_id' = ?", @trigger.id.to_s).count
  end

  test "burst control: the burst ends once the events stop, and the trigger spawns again" do
    stub_session_creation
    @trigger.update!(max_sessions_per_minute: 3)

    10.times { |i| @trigger.create_session!(prompt: "Alert #{i}") }
    assert @trigger.reload.bursting?

    # Quiet for longer than the cooldown: the burst is over.
    travel(Trigger::BURST_COOLDOWN + 1.second) do
      assert_not @trigger.reload.bursting?

      assert_difference("Session.count", 1) do
        assert_not_nil @trigger.create_session!(prompt: "A single, normal alert")
      end
      assert_equal 1, @trigger.reload.burst_window_count
    end

    assert_equal 1, burst_notice_sessions_for(@trigger).size
  end

  test "burst control: a trigger with no limit set is unbounded, exactly as before" do
    stub_session_creation
    assert_nil @trigger.max_sessions_per_minute

    assert_difference("Session.count", 10) do
      10.times { |i| assert_not_nil @trigger.create_session!(prompt: "Alert #{i}") }
    end

    assert_empty burst_notice_sessions_for(@trigger)
    assert_not @trigger.reload.bursting?
    assert_equal 0, @trigger.burst_window_count, "no cap means no burst bookkeeping"
  end

  test "burst control: the window rolls, so a steady trickle under the cap never bursts" do
    stub_session_creation
    @trigger.update!(max_sessions_per_minute: 3)

    assert_difference("Session.count", 6) do
      6.times do |i|
        travel(i * (Trigger::BURST_WINDOW + 1.second)) do
          assert_not_nil @trigger.create_session!(prompt: "Trickle #{i}")
        end
      end
    end

    assert_empty burst_notice_sessions_for(@trigger)
  end

  test "burst control: follow-ups into a reused session are not capped (they spawn nothing)" do
    stub_session_creation
    session = @trigger.create_session!(prompt: "Initial prompt")
    @trigger.update!(reuse_session: true, last_session_id: session.id, max_sessions_per_minute: 1)
    session.update_column(:status, Session.statuses[:needs_input])

    assert_no_difference("Session.count") do
      5.times do |i|
        reused = @trigger.create_session!(prompt: "Follow-up #{i}")
        assert_equal session.id, reused.id
        session.update_column(:status, Session.statuses[:needs_input])
      end
    end

    assert_empty burst_notice_sessions_for(@trigger)
    assert_not @trigger.reload.bursting?
  end

  test "burst control: the burst notice carries no goal and does not become the reuse target" do
    stub_session_creation
    @trigger.update!(max_sessions_per_minute: 1)
    assert @trigger.goal.present?, "fixture should carry a goal for this to be meaningful"

    spawned = @trigger.create_session!(prompt: "Alert 1")
    notice = @trigger.create_session!(prompt: "Alert 2")

    assert_equal true, notice.metadata["burst_notice"]
    assert_nil notice.goal, "the notice investigates the burst; the trigger's goal is not its goal"
    assert_equal spawned.goal, @trigger.goal
    assert_equal spawned.id, @trigger.reload.last_session_id
  end

  test "burst control: a burst ends after the traffic falls back under the cap, not only after total silence" do
    stub_session_creation
    @trigger.update!(max_sessions_per_minute: 3)

    # A spike opens the burst.
    10.times { |i| @trigger.create_session!(prompt: "Alert #{i}") }
    assert @trigger.reload.bursting?

    # The spike is over, but the channel keeps its ordinary trickle of one
    # message a minute — well under the cap. These are dropped while the burst
    # is still open, and crucially they must NOT keep renewing it: if every
    # dropped event pushed the cooldown out, one spike would silently disable
    # the trigger forever.
    [ 2, 3, 4 ].each do |minute|
      travel minute.minutes do
        assert_no_difference("Session.count") do
          assert_nil @trigger.create_session!(prompt: "Ordinary message at +#{minute}m")
        end
        assert @trigger.reload.bursting?, "still inside the burst, so still suppressed"
      end
    end

    # Five minutes after the last minute in which the trigger exceeded its cap,
    # the burst is over and ordinary traffic spawns sessions again — even though
    # events never stopped arriving.
    travel(Trigger::BURST_COOLDOWN + 1.minute) do
      assert_not @trigger.reload.bursting?

      assert_difference("Session.count", 1) do
        assert_not_nil @trigger.create_session!(prompt: "Back to normal")
      end
    end

    assert_equal 1, burst_notice_sessions_for(@trigger).size
  end

  test "burst control: a failed burst-notice spawn does not latch the trigger into a silent burst" do
    stub_session_creation
    @trigger.update!(max_sessions_per_minute: 1)

    @trigger.create_session!(prompt: "Alert 1")

    # The notice spawn blows up (unhealable root, DB error, ...).
    Session.stubs(:create_from_agent_root!).raises(RuntimeError, "boom")
    assert_raises(RuntimeError) { @trigger.create_session!(prompt: "Alert 2") }

    # The burst must not be left open with no notice ever sent — that is silent
    # death. It is cleared so the next fire can try the notice again.
    assert_not @trigger.reload.bursting?

    Session.unstub(:create_from_agent_root!)
    stub_session_creation

    notice = @trigger.create_session!(prompt: "Alert 3")
    assert_equal true, notice.metadata["burst_notice"]
    assert_equal 1, burst_notice_sessions_for(@trigger).size

    # ...and that retry did not spawn an ordinary session instead: the window is
    # still over the cap.
    ordinary = Session.where("metadata->>'trigger_id' = ?", @trigger.id.to_s)
      .reject { |session| session.metadata["burst_notice"] }
    assert_equal 1, ordinary.size
  end

  test "burst control: editing the cap clears a burst in progress (the operator's escape hatch)" do
    stub_session_creation
    @trigger.update!(max_sessions_per_minute: 3)
    10.times { |i| @trigger.create_session!(prompt: "Alert #{i}") }
    assert @trigger.reload.bursting?

    @trigger.update!(max_sessions_per_minute: 10)

    assert_not @trigger.bursting?
    assert_nil @trigger.burst_active_until
    assert_equal 0, @trigger.burst_window_count

    assert_difference("Session.count", 1) do
      assert_not_nil @trigger.create_session!(prompt: "After the operator raised the cap")
    end
  end

  test "burst control: clearing the cap makes the trigger unbounded again immediately" do
    stub_session_creation
    @trigger.update!(max_sessions_per_minute: 3)
    10.times { |i| @trigger.create_session!(prompt: "Alert #{i}") }
    assert @trigger.reload.bursting?

    @trigger.update!(max_sessions_per_minute: nil)

    assert_not @trigger.bursting?, "an unbounded trigger is never reported as bursting"

    assert_difference("Session.count", 5) do
      5.times { |i| assert_not_nil @trigger.create_session!(prompt: "Unbounded #{i}") }
    end
  end

  # === The seeded account_needs_reauth trigger ===
  #
  # db/migrate/20260821010100 inserts this row with raw SQL, deliberately
  # bypassing the model so a schema migration cannot depend on the AIR catalog
  # resolving. The cost of that choice is that nothing validates the row at write
  # time — so it is validated here instead, by running the migration and checking
  # what it wrote. A bad artifact id becomes a red test rather than a feature that
  # ships dead.
  #
  # The migration is run rather than assumed: fixtures wipe `triggers` before every
  # test, so the row a real `db:migrate` left behind is not present here. The test
  # transaction rolls the insert back.
  class SeededReauthTriggerTest < ActiveSupport::TestCase
    MIGRATION = Rails.root.join("db/migrate/20260821010100_seed_account_needs_reauth_trigger.rb")

    setup do
      require MIGRATION.to_s
      ActiveRecord::Migration.suppress_messages { SeedAccountNeedsReauthTrigger.new.up }

      @condition = TriggerCondition.ao_event.find { |c| c.configuration["event_name"] == "account_needs_reauth" }
      @seeded = @condition&.trigger
    end

    test "it seeds exactly one watcher for the account event" do
      matching = TriggerCondition.ao_event.count { |c| c.configuration["event_name"] == "account_needs_reauth" }

      assert_equal 1, matching, "zero is a dead feature, two is a double DM"
    end

    test "running it again is a no-op, so a re-run cannot double the notification" do
      ActiveRecord::Migration.suppress_messages { SeedAccountNeedsReauthTrigger.new.up }

      matching = TriggerCondition.ao_event.count { |c| c.configuration["event_name"] == "account_needs_reauth" }
      assert_equal 1, matching
    end

    test "down removes what up created, foreign key and all" do
      ActiveRecord::Migration.suppress_messages { SeedAccountNeedsReauthTrigger.new.down }

      assert_equal 0, TriggerCondition.ao_event.count { |c| c.configuration["event_name"] == "account_needs_reauth" }
      assert_not Trigger.exists?(@seeded.id)
    end

    test "down leaves a trigger a human has renamed alone" do
      @seeded.update_columns(name: "My own reauth handler")

      ActiveRecord::Migration.suppress_messages { SeedAccountNeedsReauthTrigger.new.down }

      assert Trigger.exists?(@seeded.id), "down must not delete a row the operator has taken ownership of"
    end

    test "the seeded row passes the validations the raw INSERT skipped" do
      assert @seeded.valid?, @seeded.errors.full_messages.join("; ")
      assert @condition.valid?, @condition.errors.full_messages.join("; ")
    end

    test "it names artifacts that resolve in the catalog" do
      assert_equal "general-agent", @seeded.agent_root_name
      assert_equal [ "slack-workspace" ], @seeded.mcp_servers
      assert_not_nil AgentRootsConfig.find!(@seeded.agent_root_name)
    end

    test "it is enabled, or the event it watches goes nowhere" do
      assert_predicate @seeded, :enabled?
    end

    # ao_event derives `spot`, and a spot session waits for a Claude account under
    # quota — which is precisely what may not exist when the pool is draining. The
    # row overrides to `priority` so the one session whose job is to report a dead
    # account is not gated behind a healthy one.
    test "its sessions are priority, not spot" do
      assert_equal SessionGenesis::PRIORITY, @seeded.effective_scheduling_class
      assert_equal SessionGenesis::SPOT, @seeded.default_scheduling_class,
        "if ao_event ever defaults to priority, the explicit override here is redundant"
    end

    # Burst suppression DROPS the fires it suppresses, and the burst case for this
    # event is a mass token revocation — precisely when every account's notification
    # matters most. The bound is upstream and durable instead: one event per account
    # per REAUTH_ALERT_THROTTLE.
    test "it carries no burst cap, because a cap here could only drop alerts" do
      assert_nil @seeded.max_sessions_per_minute
    end

    test "its prompt keeps the structure the agent has to follow" do
      assert_includes @seeded.prompt_template, "{{event}}"
      assert_includes @seeded.prompt_template, "slack-workspace"
      # The raw INSERT is one SQL statement with the prompt inlined; squishing it
      # once collapsed the numbered list into a single paragraph.
      assert_operator @seeded.prompt_template.lines.size, :>, 5, "the prompt lost its line structure"
    end
  end

  # === Regression: a recurring reuse trigger must not stack duplicate prompts ===
  #
  # The 2026-08-29 incident. Trigger 4730 ("Daily Backlog Groomer") re-uses one
  # long-lived spot session. That session sat `waiting`, held at the quota gate,
  # for six days. Every nightly fire took #follow_up_session!'s DELIVERY branch —
  # the one for an idle session — which had no duplicate guard at all, because
  # the only guard lived on the `running?` branch. #deliver_follow_up! resumed the
  # session into a job, SpotSessionHold deferred that job and converted the
  # "delivery" into one more queued row, and the cycle repeated nightly.
  #
  # Five byte-identical copies accumulated, none was ever delivered, and
  # `last_triggered_at` advanced every night — so the schedule reported six
  # consecutive successes for work that never ran. Nothing said otherwise until
  # an unrelated self-archive stranded the backlog days later.
  #
  # These tests pin the two halves of the fix: the queue must not grow, and the
  # miss must not be silent.

  # Stand in for a spot session parked at the quota gate: idle, holding an
  # undelivered prompt, taking no turns.
  def quota_held_session_for(trigger)
    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo",
      default_branch: "main",
      subdirectory: nil
    )
    AgentRootsConfig.stubs(:find!).with(trigger.agent_root_name).returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)
    AgentSessionJob.stubs(:enqueue_with_prompt)

    session = trigger.create_session!(prompt: "Initial prompt")
    trigger.update!(reuse_session: true, last_session_id: session.id)
    session.update_column(:status, Session.statuses[:waiting])
    session
  end

  # One production night, end to end.
  #
  # The trigger fires. If it DELIVERED, `deliver_follow_up!` resumed the session
  # (`waiting` -> `running`) and handed a prompt to a job — and for a spot session
  # held at the quota gate that job is refused: SpotSessionHold files the prompt
  # in `enqueued_messages` behind the turn already deferred and returns the
  # session to `waiting` (#queue_behind_scheduled_turn). Replaying that
  # conversion here is the whole point. A test that stubs
  # `AgentSessionJob.enqueue_with_prompt` and stops there removes the very
  # mechanism the queue grew through, and would pass just as well unfixed.
  #
  # The resume is what marks a delivery: a coalesced fire does not resume, so the
  # session is still `waiting` afterwards and no row is filed.
  def fire_one_night!(trigger, session, prompt)
    was_idle = session.reload.waiting?
    trigger.create_session!(prompt: prompt)

    if was_idle && session.reload.running?
      position = (session.enqueued_messages.maximum(:position) || 0) + 1
      session.enqueued_messages.create!(content: prompt, position: position, status: "pending")
      session.update_column(:status, Session.statuses[:waiting])
    end

    session.reload
  end

  test "recurring reuse trigger does not stack a second prompt onto a waiting session that already holds one" do
    session = quota_held_session_for(@trigger)
    session.enqueued_messages.create!(content: "Last night's prompt", position: 1, status: "pending")

    assert_no_difference("session.enqueued_messages.count") do
      reused = @trigger.create_session!(prompt: "Tonight's prompt")
      assert_equal session.id, reused.id
    end

    assert_equal :skipped_pending_exists, @trigger.last_follow_up_status
    # The session was NOT resumed, which is what stops the spot gate filing
    # another copy. Without this the assertion above passes unfixed too.
    assert session.reload.waiting?, "a coalesced fire must not resume the session"
  end

  test "repeated nightly fires against a quota-held session leave one prompt queued, not one per night" do
    session = quota_held_session_for(@trigger)

    6.times { fire_one_night!(@trigger, session, "Nightly prompt") }

    # Unfixed this is 6: every night took the delivery branch, which had no
    # duplicate guard, and the spot gate turned each delivery into another row.
    assert_equal 1, session.enqueued_messages.pending.count,
      "a recurring trigger stacked duplicate prompts onto a session that never consumed the first"
  end

  test "archiving after repeated coalesced fires strands one prompt rather than a nightly backlog" do
    session = quota_held_session_for(@trigger)
    6.times { fire_one_night!(@trigger, session, "Nightly prompt") }

    session.reload.archive!

    assert_equal 1, session.enqueued_messages.undelivered.count,
      "the archive stranded one message per missed night instead of the single coalesced prompt"
  end

  test "a trigger mixing recurring and one-shot conditions is never coalesced" do
    # ScheduleTriggerJob keys its auto-delete on `condition.one_time_schedule?`
    # and checks only #last_follow_up_dropped? before destroying the trigger. A
    # coalesced fire is not `:dropped`, so coalescing such a trigger would let a
    # one-shot schedule be consumed — and the trigger deleted — having delivered
    # nothing. #purely_recurring? is what keeps them out.
    @trigger.trigger_conditions.create!(
      condition_type: "schedule",
      configuration: { "type" => "one_time", "scheduled_at" => 1.day.from_now.iso8601 }
    )
    session = quota_held_session_for(@trigger)
    session.enqueued_messages.create!(content: "Queued", position: 1, status: "pending")

    assert_not @trigger.reload.purely_recurring?
    assert_not @trigger.one_time_reuse_trigger?, "fixture must be the MIXED shape, not an all-one-shot one"

    @trigger.create_session!(prompt: "Tonight")

    assert_not_equal :skipped_pending_exists, @trigger.last_follow_up_status
    assert_equal 0, @trigger.reload.missed_fire_count
  end

  test "a one-time wake trigger still delivers into a waiting session that holds a pending message" do
    trigger = triggers(:one_time_schedule_trigger)
    session = quota_held_session_for(trigger)
    assert trigger.reload.one_time_reuse_trigger?,
      "fixture must be a one-time reuse trigger for this exemption to be under test"

    session.enqueued_messages.create!(content: "Something else queued", position: 1, status: "pending")

    trigger.create_session!(prompt: "Wake up")

    # A wake is a one-shot signal, not a drumbeat: coalescing it would lose it.
    assert_equal :delivered, trigger.last_follow_up_status
  end

  # === Missed-fire bookkeeping ===

  test "a coalesced fire increments the missed-fire count and stamps when the run started" do
    session = quota_held_session_for(@trigger)
    session.enqueued_messages.create!(content: "Queued", position: 1, status: "pending")

    @trigger.create_session!(prompt: "Tonight")
    assert_equal 1, @trigger.reload.missed_fire_count
    first_at = @trigger.first_missed_fire_at
    assert_not_nil first_at

    @trigger.create_session!(prompt: "Tomorrow")
    assert_equal 2, @trigger.reload.missed_fire_count
    assert_equal first_at.to_i, @trigger.first_missed_fire_at.to_i,
      "the stamp must mark when the run of misses began, not the most recent one"
    assert @trigger.missing_fires?
  end

  test "a fire that actually lands clears the missed-fire run" do
    session = quota_held_session_for(@trigger)
    session.enqueued_messages.create!(content: "Queued", position: 1, status: "pending")
    @trigger.create_session!(prompt: "Missed")
    assert_equal 1, @trigger.reload.missed_fire_count

    # The session takes its turn and the queue drains.
    session.enqueued_messages.destroy_all

    @trigger.create_session!(prompt: "Landed")

    assert_equal 0, @trigger.reload.missed_fire_count
    assert_nil @trigger.first_missed_fire_at
    assert_not @trigger.missing_fires?
  end

  test "a run of coalesced fires against a stale queue raises an alert" do
    session = quota_held_session_for(@trigger)
    message = session.enqueued_messages.create!(content: "Queued", position: 1, status: "pending")
    message.update_column(:created_at, (Trigger::MISSED_FIRE_MIN_QUEUE_AGE + 1.hour).ago)

    raised = []
    AlertService.stubs(:raise_alert).with { |title, **| raised << title; true }

    Trigger::MISSED_FIRE_ALERT_THRESHOLD.times { @trigger.create_session!(prompt: "Nightly") }

    assert_includes raised, "Recurring trigger is not reaching its session"
  end

  test "a single coalesced fire does not alert" do
    session = quota_held_session_for(@trigger)
    message = session.enqueued_messages.create!(content: "Queued", position: 1, status: "pending")
    message.update_column(:created_at, (Trigger::MISSED_FIRE_MIN_QUEUE_AGE + 1.hour).ago)

    raised = []
    AlertService.stubs(:raise_alert).with { |title, **| raised << title; true }

    @trigger.create_session!(prompt: "Nightly")

    assert_not_includes raised, "Recurring trigger is not reaching its session"
  end

  test "coalesced fires against a queue that is merely busy do not alert" do
    session = quota_held_session_for(@trigger)
    # Queued moments ago: a session mid-turn, not a session that cannot consume.
    session.enqueued_messages.create!(content: "Queued", position: 1, status: "pending")

    raised = []
    AlertService.stubs(:raise_alert).with { |title, **| raised << title; true }

    (Trigger::MISSED_FIRE_ALERT_THRESHOLD + 1).times { @trigger.create_session!(prompt: "Nightly") }

    assert_not_includes raised, "Recurring trigger is not reaching its session"
  end

  # === skip_if_pending_session is inert on the reuse path ===

  test "a fresh spawn clears a missed-fire run left by the session it replaced" do
    session = quota_held_session_for(@trigger)
    session.enqueued_messages.create!(content: "Queued", position: 1, status: "pending")
    @trigger.create_session!(prompt: "Missed")
    assert_equal 1, @trigger.reload.missed_fire_count

    # The reuse candidate becomes unusable, so the next fire spawns instead. The
    # count belonged to the old session's queue and must not follow the trigger.
    session.update_column(:status, Session.statuses[:failed])

    @trigger.create_session!(prompt: "Fresh")

    assert_equal 0, @trigger.reload.missed_fire_count
    assert_nil @trigger.first_missed_fire_at
  end

  test "a dropped follow-up neither counts as a miss nor clears an existing run" do
    session = quota_held_session_for(@trigger)
    @trigger.update!(enqueue_messages: false)
    session.enqueued_messages.create!(content: "Queued", position: 1, status: "pending")
    @trigger.create_session!(prompt: "Missed")
    assert_equal 1, @trigger.reload.missed_fire_count

    # Busy session, enqueue_messages off, and nothing left in the queue: the
    # follow-up is dropped by the pre-existing "don't barge" rule.
    session.enqueued_messages.destroy_all
    session.update_column(:status, Session.statuses[:running])

    @trigger.create_session!(prompt: "Dropped")

    assert_equal :dropped, @trigger.last_follow_up_status
    assert_equal 1, @trigger.reload.missed_fire_count,
      "a dropped follow-up is not progress and must not clear a run of real misses"
  end

  # === #704: a fire that raises after the session row exists ===

  test "last_fire_created_session names the session a fire created, even when the fire then raised" do
    # Creating a session is two steps and only the first is a database write.
    # Session.create_from_agent_root! commits the row and then enqueues the one
    # AgentSessionJob the session's first turn rides on; #create_session! keeps
    # working after that. A caller whose only signal is the return value cannot
    # tell "nothing was created" from "created, then the enqueue fell over" — and
    # putting the event back on the second reading is how trigger 352 spawned two
    # merge-gate sessions for one `ready to merge` label.
    @trigger.update!(reuse_session: false)
    AgentSessionJob.stubs(:enqueue_new_session).raises(RuntimeError, "the agents queue is unreachable")

    created = nil
    assert_difference "Session.count", 1 do
      assert_raises(RuntimeError) { @trigger.create_session!(prompt: "Rate this PR") }
      created = @trigger.last_fire_created_session
    end

    assert_not_nil created, "the fire raised, but it left a real session behind"
    assert_equal Session.order(:id).last.id, created.id
  end

  test "last_fire_created_session survives a raise from the session's own after_commit callbacks" do
    # The narrow reading of this — "report the session once #save! has returned" —
    # misses the widest way a fire raises over a committed row. Rails runs
    # after_create_commit INSIDE #save!, and two of Session's are unrescued: one does
    # a Turbo/Redis broadcast, the other enqueues SessionTitleJob. A Redis blip or a
    # failed GoodJob enqueue in either comes back out of #save! with the row already
    # written, and it happens BEFORE AgentSessionJob.enqueue_new_session is reached.
    @trigger.update!(reuse_session: false)
    Session.any_instance.stubs(:enqueue_session_inference).raises(RuntimeError, "redis is unreachable")

    assert_difference "Session.count", 1 do
      assert_raises(RuntimeError) { @trigger.create_session!(prompt: "Rate this PR") }
    end

    assert_not_nil @trigger.last_fire_created_session,
      "the row was written before the callback raised, so the fire did create a session"
    assert_equal Session.order(:id).last.id, @trigger.last_fire_created_session.id
  end

  test "last_fire_created_session is nil when the fire raised before creating anything" do
    # The other direction, and the one that must not be traded away: a fire that
    # never got as far as a session row is a DROPPED event, and a caller holding a
    # retryable one has to put it back. #647 is that failure — a `ready to merge`
    # label swallowed, leaving a PR waiting forever with nobody to notice.
    @trigger.update!(reuse_session: false)
    AgentRootsConfig.stubs(:find!).raises(AgentRootsConfig::AgentRootNotFoundError, "gone")

    assert_no_difference "Session.count" do
      assert_raises(AgentRootsConfig::AgentRootNotFoundError) { @trigger.create_session!(prompt: "Rate this PR") }
    end

    assert_nil @trigger.last_fire_created_session
  end

  test "last_fire_created_session is cleared by the next fire rather than carried into it" do
    # Read after a raise, so it cannot be reset on the way out. It is reset on the
    # way IN instead, which is what stops a second item in the same tick — same
    # in-memory trigger — from being credited with the first item's session.
    @trigger.update!(reuse_session: false)

    @trigger.create_session!(prompt: "First")
    first = @trigger.last_fire_created_session
    assert_not_nil first

    AgentRootsConfig.stubs(:find!).raises(AgentRootsConfig::AgentRootNotFoundError, "gone")
    assert_raises(AgentRootsConfig::AgentRootNotFoundError) { @trigger.create_session!(prompt: "Second") }

    assert_nil @trigger.last_fire_created_session,
      "the second fire created nothing; it must not report the first fire's session"
  end

  test "skip_if_pending_session_inert? is true for a reuse trigger and false for a spawning one" do
    @trigger.update!(skip_if_pending_session: true, reuse_session: false)
    assert_not @trigger.skip_if_pending_session_inert?

    @trigger.update!(reuse_session: true)
    assert @trigger.skip_if_pending_session_inert?

    @trigger.update!(skip_if_pending_session: false)
    assert_not @trigger.skip_if_pending_session_inert?
  end

  # A per-session wake-up trigger in the shape Sessions::ScheduleWakeUp builds:
  # reuse_session + last_session_id + a single one-time schedule.
  def wake_trigger_for(session, agent_root_name:)
    Trigger.create!(
      name: "Wake session ##{session.id}",
      agent_root_name: agent_root_name,
      prompt_template: "Resume",
      reuse_session: true,
      last_session_id: session.id,
      trigger_conditions_attributes: [
        {
          condition_type: "schedule",
          configuration: {
            "scheduled_at" => 1.hour.from_now.utc.strftime("%Y-%m-%dT%H:%M:%S"),
            "timezone" => "UTC"
          }
        }
      ]
    )
  end
end
