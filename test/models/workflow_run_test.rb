# frozen_string_literal: true

require "test_helper"

class WorkflowRunTest < ActiveSupport::TestCase
  setup do
    @session = Session.create_from_agent_root!(agent_root_name: "zimmer", prompt: "Restate: hi", skip_enqueue: true)
    @trigger = triggers(:enabled_schedule_trigger)
  end

  def create_run(**attributes)
    WorkflowRun.create!({ session: @session, trigger: @trigger, workflow_id: "echo", input: { "message" => "hi" }, resolved: {} }.merge(attributes))
  end

  test "a persisted run is read-only: resolved cannot be rewritten by any path" do
    run = create_run(resolved: { "reply_channel_id" => "C123" })

    assert_raises(ActiveRecord::ReadOnlyRecord) { run.update!(resolved: { "reply_channel_id" => "C999" }) }
    assert_raises(ActiveRecord::ReadOnlyRecord) { run.update_columns(resolved: { "reply_channel_id" => "C999" }) }
    assert_equal({ "reply_channel_id" => "C123" }, WorkflowRun.find(run.id).resolved)
  end

  test "one run per session" do
    create_run

    assert_raises(ActiveRecord::RecordNotUnique) { WorkflowRun.create!(session: @session, workflow_id: "echo") }
  end

  test "input and resolved are objects" do
    run = WorkflowRun.new(session: @session, workflow_id: "echo", input: [ "hi" ], resolved: "C123")

    assert_not run.valid?
    assert_includes run.errors[:input], "must be an object"
    assert_includes run.errors[:resolved], "must be an object"
  end

  test "deleting the session deletes its run" do
    run = create_run

    Session.where(id: @session.id).delete_all

    assert_not WorkflowRun.exists?(run.id)
  end

  test "deleting the trigger keeps the run and forgets the trigger" do
    run = create_run

    @trigger.destroy!

    assert_nil WorkflowRun.find(run.id).trigger_id
  end
end
