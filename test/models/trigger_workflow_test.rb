# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# A trigger may run a workflow instead of rendering a template (#18, Phase 0).
# The first test here is the one that matters most: every trigger that predates
# workflows is still a template trigger that validates the way it did.
class TriggerWorkflowTest < ActiveSupport::TestCase
  SCHEDULE = {
    condition_type: "schedule",
    configuration: { "interval" => 1, "unit" => "days", "time" => "09:00", "timezone" => "Eastern Time (US & Canada)" }
  }.freeze

  class RootedWorkflow < ApplicationWorkflow
    workflow_id "test.rooted"
    title "Rooted"
    description "Test-only: declares an agent root."
    requires agent_root: "zimmer"

    def plan(_input) = Workflow::Plan.new(resolved: {}, instructions: "x")
  end

  def workflow_trigger(**attributes)
    Trigger.new({ name: "Echo", agent_root_name: "zimmer", workflow_id: "echo", trigger_conditions_attributes: [ SCHEDULE ] }.merge(attributes))
  end

  test "every existing trigger is still a template trigger, and the template rule reads the same" do
    Trigger.find_each do |trigger|
      assert_not trigger.workflow_backed?, trigger.name
      trigger.valid?
      assert_empty trigger.errors[:prompt_template], trigger.name
      assert_empty trigger.errors[:workflow_id], trigger.name
    end

    template = triggers(:enabled_slack_trigger)
    template.prompt_template = nil
    assert_not template.valid?
    assert_equal [ "can't be blank" ], template.errors[:prompt_template]
  end

  test "a workflow trigger needs no template" do
    trigger = workflow_trigger

    assert trigger.save, trigger.errors.full_messages.to_sentence
    assert trigger.workflow_backed?
    assert_nil trigger.reload.prompt_template
    assert_equal EchoWorkflow, trigger.workflow
    assert_equal [], trigger.prompt_variables
    assert_not trigger.references_github_context?
  end

  test "a trigger may not have both a template and a workflow" do
    trigger = workflow_trigger(prompt_template: "Say {{text}}")

    assert_not trigger.valid?
    assert_includes trigger.errors[:prompt_template], "must be blank when the trigger runs a workflow"
  end

  test "a blank workflow id is no workflow, so the template is required again" do
    trigger = workflow_trigger(workflow_id: "  ")

    assert_nil trigger.workflow_id
    assert_not trigger.valid?
    assert_includes trigger.errors[:prompt_template], "can't be blank"
  end

  test "the workflow has to be registered" do
    trigger = workflow_trigger(workflow_id: "slack.triage_mention")

    assert_not trigger.valid?
    assert_includes trigger.errors[:workflow_id], "is not a registered workflow"
  end

  test "a workflow trigger may not reuse a session" do
    trigger = workflow_trigger(reuse_session: true)

    assert_not trigger.valid?
    assert_includes trigger.errors[:reuse_session], "cannot be used by a trigger that runs a workflow"
  end

  test "a workflow trigger carries no equipment of its own" do
    trigger = workflow_trigger(mcp_servers: %w[context7], catalog_skills: %w[wait-for-ci], goal: "PR is merged")

    assert_not trigger.valid?
    assert_match "must be empty when the trigger runs a workflow", trigger.errors[:mcp_servers].to_sentence
    assert_match "must be empty when the trigger runs a workflow", trigger.errors[:catalog_skills].to_sentence
    assert_match "must be blank when the trigger runs a workflow", trigger.errors[:goal].to_sentence
  end

  test "a workflow that declares an agent root pins the trigger to it" do
    WorkflowRegistry.stubs(:registered?).with("test.rooted").returns(true)
    WorkflowRegistry.stubs(:find!).with("test.rooted").returns(RootedWorkflow)

    assert workflow_trigger(workflow_id: "test.rooted").valid?

    elsewhere = workflow_trigger(workflow_id: "test.rooted", agent_root_name: "general-agent")
    assert_not elsewhere.valid?
    assert_includes elsewhere.errors[:agent_root_name], "must be \"zimmer\", the agent root workflow \"test.rooted\" declares"
  end

  test "the database holds exactly-one-of too, whatever skips the model" do
    # Each violation in its own savepoint: a failed statement aborts the
    # transaction it runs in, and the test's own would take the next one with it.
    neither = triggers(:enabled_slack_trigger)
    assert_raises(ActiveRecord::CheckViolation) do
      Trigger.transaction(requires_new: true) { neither.update_column(:prompt_template, nil) }
    end

    both = triggers(:enabled_schedule_trigger)
    assert_raises(ActiveRecord::CheckViolation) do
      Trigger.transaction(requires_new: true) { both.update_column(:workflow_id, "echo") }
    end
  end

  test "a blank template on a workflow trigger is no template, as every edit form submits one" do
    trigger = workflow_trigger(prompt_template: "")

    assert trigger.save, trigger.errors.full_messages.to_sentence
    assert_nil trigger.reload.prompt_template

    assert trigger.update(prompt_template: "  ", name: "Echo, renamed")
    assert_nil trigger.reload.prompt_template
  end

  test "the database refuses a workflow trigger that reuses a session, whatever skips the model" do
    trigger = workflow_trigger
    trigger.save!

    assert_raises(ActiveRecord::CheckViolation) do
      Trigger.transaction(requires_new: true) { trigger.update_column(:reuse_session, true) }
    end
  end

  test "a workflow trigger refuses a reuse fire even when its reuse flag was never saved" do
    trigger = workflow_trigger
    trigger.save!
    trigger.reuse_session = true

    assert_no_difference([ "Session.count", "WorkflowRun.count" ]) do
      error = assert_raises(ArgumentError) do
        trigger.create_session!(prompt: "hi", workflow_run: WorkflowRun.new(workflow_id: "echo", trigger: trigger))
      end
      assert_match "never reuses a session", error.message
    end
  end

  test "a workflow trigger refuses a template fire, loudly, and spawns nothing" do
    trigger = workflow_trigger
    trigger.save!

    assert_no_difference("Session.count") do
      assert_raises(ArgumentError) { trigger.interpolate_prompt(text: "hi") }
      error = assert_raises(ArgumentError) { trigger.create_session!(prompt: "hi") }
      assert_match "is fired through WorkflowRunner", error.message
    end
  end

  test "a template trigger refuses a workflow run" do
    trigger = triggers(:enabled_schedule_trigger)

    assert_no_difference([ "Session.count", "WorkflowRun.count" ]) do
      assert_raises(ArgumentError) { trigger.create_session!(prompt: "hi", workflow_run: WorkflowRun.new(workflow_id: "echo")) }
    end
  end
end
