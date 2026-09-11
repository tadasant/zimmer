# frozen_string_literal: true

require "test_helper"

class WorkflowRegistryTest < ActiveSupport::TestCase
  test "finds a registered workflow by its id" do
    assert_equal EchoWorkflow, WorkflowRegistry.find!("echo")
    assert WorkflowRegistry.registered?("echo")
  end

  test "an unknown id raises, as a KeyError, rather than guessing" do
    error = assert_raises(WorkflowRegistry::UnknownWorkflowError) { WorkflowRegistry.find!("slack.triage_mention") }

    assert_kind_of KeyError, error
    assert_match "slack.triage_mention", error.message
    assert_raises(WorkflowRegistry::UnknownWorkflowError) { WorkflowRegistry.find!(nil) }
    assert_not WorkflowRegistry.registered?("slack.triage_mention")
    assert_not WorkflowRegistry.registered?(nil)
  end

  # The registry is written by hand, so the two ways it can be wrong are a
  # workflow nobody registered and two workflows claiming one id — which
  # `index_by` would settle silently, in favour of whichever came last.
  test "every workflow class under app/workflows is registered, under its own id" do
    Rails.autoloaders.main.eager_load_dir(Rails.root.join("app/workflows").to_s)

    defined = ApplicationWorkflow.subclasses.select do |klass|
      klass.name && Object.const_source_location(klass.name)&.first.to_s.start_with?(Rails.root.join("app/workflows").to_s)
    end

    assert_equal defined.sort_by(&:name), WorkflowRegistry.all.sort_by(&:name)
    WorkflowRegistry::WORKFLOWS.each { |id, workflow| assert_equal id, workflow.workflow_id }
  end

  test "every registered workflow is complete" do
    WorkflowRegistry.all.each do |workflow|
      assert_operator workflow, :<, ApplicationWorkflow
      assert_predicate workflow.title, :present?, "#{workflow.name} declares no title"
      assert_predicate workflow.description, :present?, "#{workflow.name} declares no description"
      assert_not_equal ApplicationWorkflow, workflow.instance_method(:plan).owner, "#{workflow.name} does not implement #plan"
    end
  end
end
