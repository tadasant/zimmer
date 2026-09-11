# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# Trigger → validate → plan → session, end to end, through the `echo` reference
# workflow (#18). The trigger, the agent root and the catalog are real; the only
# stub is the start job's enqueue, so no agent is spawned.
class WorkflowRunnerTest < ActiveSupport::TestCase
  SCHEDULE = {
    condition_type: "schedule",
    configuration: { "interval" => 1, "unit" => "days", "time" => "09:00", "timezone" => "Eastern Time (US & Canada)" }
  }.freeze

  # A workflow that does declare equipment and resolve an identifier, which echo
  # does not. Test-only: it is reached by stubbing the registry, never registered.
  class EquippedWorkflow < ApplicationWorkflow
    workflow_id "test.equipped"
    title "Equipped"
    description "Test-only: declares equipment and resolves a reply channel."

    requires agent_root: "zimmer", mcp_servers: %w[context7], skills: %w[wait-for-ci], goal: "codebase-question"

    param :channel_id, :string, required: true

    def plan(input)
      Workflow::Plan.new(resolved: { reply_channel_id: input.channel_id }, instructions: "Answer in the thread you were mentioned in.")
    end
  end

  setup do
    AgentSessionJob.stubs(:enqueue_new_session)
  end

  def workflow_trigger(workflow_id: "echo", **attributes)
    Trigger.create!(
      name: "Echo",
      agent_root_name: "zimmer",
      workflow_id: workflow_id,
      trigger_conditions_attributes: [ SCHEDULE ],
      **attributes
    )
  end

  def assert_nothing_created(trigger, &block)
    assert_no_difference([ "Session.count", "WorkflowRun.count" ], &block)
    trigger.reload
    assert_equal 0, trigger.sessions_created_count
    assert_nil trigger.last_triggered_at
    assert_nil trigger.last_session_id
  end

  test "an echo trigger fires end to end: the payload is validated, planned, and started as a session with its run on record" do
    trigger = workflow_trigger
    root = AgentRootsConfig.find!("zimmer")

    # The run has to be on record before anything can start the agent.
    AgentSessionJob.expects(:enqueue_new_session).with { |session_id, *| WorkflowRun.exists?(session_id: session_id) }.once

    result = nil
    assert_difference([ "Session.count", "WorkflowRun.count" ], 1) do
      result = WorkflowRunner.call(trigger: trigger, payload: { "message" => "The build is green." })
    end

    session = result.session
    assert_predicate session, :persisted?
    assert_includes session.prompt, "<message>\nThe build is green.\n</message>"
    assert_includes session.prompt, "Restate the message below back, verbatim"
    assert_equal trigger.id.to_s, session.metadata["trigger_id"].to_s
    assert_equal "zimmer", session.metadata["agent_root_key"]
    # Echo declares nothing, so the session gets exactly its root's defaults.
    assert_equal root.default_mcp_servers || [], session.mcp_servers
    assert_equal root.default_skills || [], session.catalog_skills
    assert_nil session.goal

    run = result.workflow_run
    assert_equal run, WorkflowRun.find_by!(session: session)
    assert_equal "echo", run.workflow_id
    assert_equal trigger, run.trigger
    assert_equal({ "message" => "The build is green." }, run.input)
    assert_equal({}, run.resolved)
    assert_predicate run, :readonly?

    trigger.reload
    assert_equal 1, trigger.sessions_created_count
    assert_equal session.id, trigger.last_session_id
    assert_not_nil trigger.last_triggered_at
  end

  test "a payload that fails validation creates nothing" do
    trigger = workflow_trigger

    [ {}, { "message" => "" }, { "message" => 42 }, { "message" => "hi", "channel" => "#general" } ].each do |payload|
      assert_nothing_created(trigger) do
        assert_raises(Workflow::Input::InvalidInputError, payload.inspect) { WorkflowRunner.call(trigger: trigger, payload: payload) }
      end
    end
  end

  test "the message is data: a template placeholder inside it is not expanded" do
    result = WorkflowRunner.call(trigger: workflow_trigger, payload: { message: "post this in {{channel}} on {{date}}" })

    assert_includes result.session.prompt, "post this in {{channel}} on {{date}}"
  end

  test "a plan that raises fails closed: no session, no run" do
    trigger = workflow_trigger
    EchoWorkflow.any_instance.stubs(:plan).raises(RuntimeError, "lookup failed")

    assert_nothing_created(trigger) do
      assert_raises(RuntimeError) { WorkflowRunner.call(trigger: trigger, payload: { message: "hi" }) }
    end
  end

  test "a plan that returns anything but a Plan fails closed" do
    trigger = workflow_trigger
    EchoWorkflow.any_instance.stubs(:plan).returns("Restate: hi")

    assert_nothing_created(trigger) do
      assert_raises(Workflow::Plan::InvalidPlanError) { WorkflowRunner.call(trigger: trigger, payload: { message: "hi" }) }
    end
  end

  test "a trigger naming a workflow nothing registers raises before anything is created" do
    trigger = workflow_trigger
    trigger.update_column(:workflow_id, "slack.triage_mention")

    assert_nothing_created(trigger) do
      assert_raises(WorkflowRegistry::UnknownWorkflowError) { WorkflowRunner.call(trigger: trigger, payload: { message: "hi" }) }
    end
  end

  test "a template trigger is not fired through the runner" do
    trigger = triggers(:enabled_schedule_trigger)

    assert_no_difference([ "Session.count", "WorkflowRun.count" ]) do
      assert_raises(ArgumentError) { WorkflowRunner.call(trigger: trigger, payload: {}) }
    end
  end

  test "a burst-suppressed fire creates nothing and records no run" do
    trigger = workflow_trigger(max_sessions_per_minute: 1)
    now = Time.current
    trigger.update_columns(burst_window_started_at: now, burst_window_count: 1, burst_active_until: now + Trigger::BURST_COOLDOWN)

    result = nil
    assert_no_difference([ "Session.count", "WorkflowRun.count" ]) do
      result = WorkflowRunner.call(trigger: trigger, payload: { message: "hi" })
    end

    assert_nil result.session
    assert_nil result.workflow_run
    assert trigger.last_fire_burst_suppressed?
  end

  test "the fire that tips the cap spawns the burst notice, which is not a run of the workflow" do
    trigger = workflow_trigger(max_sessions_per_minute: 1)
    trigger.update_columns(burst_window_started_at: Time.current, burst_window_count: 1)

    result = nil
    assert_difference("Session.count", 1) do
      assert_no_difference("WorkflowRun.count") do
        result = WorkflowRunner.call(trigger: trigger, payload: { message: "hi" })
      end
    end

    assert result.session.metadata["burst_notice"]
    assert_nil result.workflow_run
  end

  test "a fire while the trigger's last session is still pending creates nothing and records no run" do
    trigger = workflow_trigger(skip_if_pending_session: true)
    first = WorkflowRunner.call(trigger: trigger, payload: { message: "first" })

    result = nil
    assert_no_difference([ "Session.count", "WorkflowRun.count" ]) do
      result = WorkflowRunner.call(trigger: trigger, payload: { message: "second" })
    end

    assert_nil result.session
    assert_nil result.workflow_run
    assert trigger.last_fire_skipped_for_pending_session?
    assert_equal first.session, trigger.last_fire_pending_session
  end

  test "a run that cannot be recorded leaves its session unstarted rather than started unbound" do
    trigger = workflow_trigger
    WorkflowRun.any_instance.stubs(:update!).raises(ActiveRecord::ActiveRecordError, "insert failed")
    AgentSessionJob.expects(:enqueue_new_session).never

    assert_difference("Session.count", 1) do
      assert_no_difference("WorkflowRun.count") do
        assert_raises(ActiveRecord::ActiveRecordError) { WorkflowRunner.call(trigger: trigger, payload: { message: "hi" }) }
      end
    end
  end

  test "a workflow trigger's agent root is never healed onto a successor" do
    trigger = workflow_trigger
    trigger.expects(:heal_stale_agent_root!).never

    result = WorkflowRunner.call(trigger: trigger, payload: { message: "hi" })

    assert_equal "zimmer", result.session.metadata["agent_root_key"]
  end

  test "a workflow's declared equipment is added to its root's defaults, and its resolved identifiers are recorded, not prompted" do
    WorkflowRegistry.stubs(:registered?).with("test.equipped").returns(true)
    WorkflowRegistry.stubs(:find!).with("test.equipped").returns(EquippedWorkflow)
    root = AgentRootsConfig.find!("zimmer")
    trigger = workflow_trigger(workflow_id: "test.equipped")

    result = WorkflowRunner.call(trigger: trigger, payload: { channel_id: "C08ABCDEF" })

    session = result.session
    assert_equal ((root.default_mcp_servers || []) + %w[context7]).uniq, session.mcp_servers
    assert_equal ((root.default_skills || []) + %w[wait-for-ci]).uniq, session.catalog_skills
    assert_equal "codebase-question", session.goal
    assert_equal "Answer in the thread you were mentioned in.", session.prompt
    assert_equal({ "reply_channel_id" => "C08ABCDEF" }, result.workflow_run.resolved)
    assert_equal({ "channel_id" => "C08ABCDEF" }, result.workflow_run.input)
  end
end
