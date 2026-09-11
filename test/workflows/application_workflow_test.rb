# frozen_string_literal: true

require "test_helper"

# The contract every workflow is written against (#18): the declarations, the
# strict input boundary, and the shape of a plan.
class ApplicationWorkflowTest < ActiveSupport::TestCase
  # A fresh workflow per test, so no declaration leaks from one test into another.
  def build_workflow(&block)
    Class.new(ApplicationWorkflow) do
      def self.name = "TestWorkflow"

      class_eval(&block) if block
    end
  end

  def typed_workflow
    build_workflow do
      workflow_id "test.typed"
      param :text, :text, required: true
      param :count, :integer
      param :dry_run, :boolean, required: true
      param :for_date, :date
      param :tone, :string, options: %w[terse warm]
    end
  end

  def errors_for(workflow, payload)
    error = assert_raises(Workflow::Input::InvalidInputError) { workflow.build_input!(payload) }
    error.input.errors
  end

  # --- Declarations ----------------------------------------------------------

  test "declares its id, title and description" do
    workflow = build_workflow do
      workflow_id "reports.nightly_digest"
      title "Nightly digest"
      description "Summarise the day."
    end

    assert_equal "reports.nightly_digest", workflow.workflow_id
    assert_equal "Nightly digest", workflow.title
    assert_equal "Summarise the day.", workflow.description
  end

  test "a workflow id must be dotted lower-snake segments" do
    [ "Echo", "slack triage", "slack..triage", ".echo", "1echo" ].each do |bad|
      assert_raises(ArgumentError, bad) { build_workflow { workflow_id bad } }
    end
  end

  test "a workflow id is declared once and cannot be re-pointed" do
    error = assert_raises(ArgumentError) do
      build_workflow do
        workflow_id "first"
        workflow_id "second"
      end
    end

    assert_match "already declares workflow id \"first\"", error.message
  end

  test "params are descriptors, kept in declaration order, with a humanized label by default" do
    workflow = build_workflow do
      param :channel_id, :string, required: true, label: "Channel ID", help: "Where it was posted", example: "C08ABCDEF"
      param :message_text, :text, widget: :textarea
    end

    first, second = workflow.params
    assert_equal [ :channel_id, :message_text ], workflow.params.map(&:key)
    assert_equal "Channel ID", first.label
    assert first.required
    assert_equal "Where it was posted", first.help
    assert_equal "C08ABCDEF", first.example
    assert_equal "Message text", second.label
    assert_equal :textarea, second.widget
    assert_not second.required
  end

  test "a param of an unknown type, or declared twice, is refused at declaration" do
    assert_raises(ArgumentError) { build_workflow { param :when, :datetime } }
    assert_raises(ArgumentError) do
      build_workflow do
        param :message, :text
        param :message, :string
      end
    end
  end

  test "each workflow validates against its own params only" do
    one = build_workflow { param :message, :text, required: true }
    other = build_workflow { param :count, :integer, required: true }

    assert_equal [ "message" ], one.input_class.attribute_names
    assert_equal [ "count" ], other.input_class.attribute_names
  end

  test "a workflow that declares no requirements needs nothing from the catalog" do
    requirements = build_workflow.requirements

    assert_nil requirements.agent_root
    assert_equal [], requirements.mcp_servers
    assert_equal [], requirements.skills
    assert_nil requirements.goal
  end

  test "requires records catalog names as strings" do
    workflow = build_workflow { requires agent_root: :zimmer, mcp_servers: [ :context7 ], skills: "wait-for-ci", goal: "codebase-question" }

    assert_equal "zimmer", workflow.requirements.agent_root
    assert_equal [ "context7" ], workflow.requirements.mcp_servers
    assert_equal [ "wait-for-ci" ], workflow.requirements.skills
    assert_equal "codebase-question", workflow.requirements.goal
  end

  test "a workflow that does not implement plan says so" do
    workflow = build_workflow { param :message, :text }

    assert_raises(NotImplementedError) { workflow.new.plan(workflow.build_input!({})) }
  end

  # --- The input boundary ----------------------------------------------------

  test "a well-formed payload validates and casts, with string or symbol keys" do
    input = typed_workflow.build_input!(text: "hi", "count" => "42", dry_run: "false", for_date: "2026-09-11", tone: "warm")

    assert_equal "hi", input.text
    assert_equal 42, input.count
    assert_equal false, input.dry_run
    assert_equal Date.new(2026, 9, 11), input.for_date
    assert_equal "warm", input.tone
  end

  test "a missing or blank required param is refused" do
    assert_includes errors_for(typed_workflow, { dry_run: true })[:text], "can't be blank"
    assert_includes errors_for(typed_workflow, { text: "   ", dry_run: true })[:text], "can't be blank"
  end

  test "false satisfies a required boolean" do
    assert_equal false, typed_workflow.build_input!(text: "hi", dry_run: false).dry_run
  end

  test "an unknown key is refused, not dropped" do
    errors = errors_for(typed_workflow, { text: "hi", dry_run: true, channel: "#general", extra: 1 })

    assert_includes errors[:base], "unknown parameters: channel, extra"
  end

  test "a value that is not its declared type is refused rather than coerced" do
    workflow = typed_workflow

    # ActiveModel on its own would cast every one of these to something.
    assert_includes errors_for(workflow, { text: 5, dry_run: true })[:text], "must be a string"
    assert_includes errors_for(workflow, { text: "hi", dry_run: true, count: "abc" })[:count], "must be an integer"
    assert_includes errors_for(workflow, { text: "hi", dry_run: true, count: 4.5 })[:count], "must be an integer"
    assert_includes errors_for(workflow, { text: "hi", dry_run: "yes" })[:dry_run], "must be true or false"
    assert_includes errors_for(workflow, { text: "hi", dry_run: true, for_date: "tomorrow" })[:for_date], "must be a date (YYYY-MM-DD)"
    assert_includes errors_for(workflow, { text: "hi", dry_run: true, for_date: "2026-02-30" })[:for_date], "must be a date (YYYY-MM-DD)"
  end

  test "a param with options accepts only those" do
    assert_includes errors_for(typed_workflow, { text: "hi", dry_run: true, tone: "shouty" })[:tone], "is not included in the list"
  end

  test "every problem is reported at once" do
    error = assert_raises(Workflow::Input::InvalidInputError) do
      typed_workflow.build_input!(count: "abc", nonsense: true)
    end

    assert_match "test.typed", error.message
    assert_equal %i[base text dry_run count].sort, error.input.errors.attribute_names.sort
  end

  test "a payload that is not a Hash is a programming error" do
    assert_raises(ArgumentError) { typed_workflow.build_input!("text=hi") }
  end

  test "to_h is every declared param, cast, with nil for an optional one not supplied" do
    input = typed_workflow.build_input!(text: "hi", dry_run: true)

    assert_equal(
      { "text" => "hi", "count" => nil, "dry_run" => true, "for_date" => nil, "tone" => nil },
      input.to_h
    )
  end

  # --- The plan --------------------------------------------------------------

  test "a plan keeps resolved and instructions apart, with resolved keys as strings" do
    plan = Workflow::Plan.new(resolved: { reply_channel_id: "C123", principal: { slack_user_id: "U1" } }, instructions: "Answer it.")

    assert_equal({ "reply_channel_id" => "C123", "principal" => { "slack_user_id" => "U1" } }, plan.resolved)
    assert_equal "Answer it.", plan.instructions
  end

  test "a plan refuses resolved values that would not survive the trip through jsonb" do
    assert_raises(Workflow::Plan::InvalidPlanError) { Workflow::Plan.new(resolved: "C123", instructions: "x") }
    assert_raises(Workflow::Plan::InvalidPlanError) { Workflow::Plan.new(resolved: { channel: :general }, instructions: "x") }
    assert_raises(Workflow::Plan::InvalidPlanError) { Workflow::Plan.new(resolved: { at: Time.current }, instructions: "x") }
  end

  test "a plan needs instructions" do
    assert_raises(Workflow::Plan::InvalidPlanError) { Workflow::Plan.new(resolved: {}, instructions: "  ") }
    assert_raises(Workflow::Plan::InvalidPlanError) { Workflow::Plan.new(resolved: {}, instructions: nil) }
  end
end
