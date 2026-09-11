# frozen_string_literal: true

# Fires a workflow-backed trigger (#18): trigger → validate → plan → session.
#
#   1. Look the trigger's workflow up in WorkflowRegistry. An id nothing
#      registers raises; nothing guesses.
#   2. Validate the payload against the workflow's params. A payload that fails
#      raises Workflow::Input::InvalidInputError, before a session exists.
#   3. Plan. #plan may look things up and may raise, and a raise here leaves no
#      session behind either — that is what failing closed means.
#   4. Spawn through the trigger's own path, Trigger#create_session!, so a
#      workflow fire gets the burst cap, pending-session dedup, genesis and fire
#      counters a template fire gets. The workflow's `instructions` are the
#      prompt, and its requirements — not the trigger's columns — are what the
#      session is equipped with.
#   5. Record the run. The WorkflowRun row is written the moment the session row
#      commits and before its start job is enqueued, so by the time anything
#      spawns the agent, `resolved` is already on record.
#
# Nothing fires this in production yet. This is Phase 0 of #18 — the contract —
# and every firing site still fires a trigger through its template. A workflow
# trigger reaching one of them raises in Trigger#interpolate_prompt rather than
# rendering a prompt it does not have.
class WorkflowRunner
  # `session` is nil when the trigger's spawn policy created nothing (it is
  # burst-suppressed, or a session it already spawned is still pending), and is
  # the burst-notice session when this fire tipped the cap. `workflow_run` is
  # set only when the workflow's own session was created.
  Result = Data.define(:session, :workflow_run)

  def self.call(trigger:, payload:, genesis: nil)
    new(trigger: trigger, payload: payload, genesis: genesis).call
  end

  def initialize(trigger:, payload:, genesis: nil)
    @trigger = trigger
    @payload = payload
    @genesis = genesis
  end

  def call
    unless @trigger.workflow_backed?
      raise ArgumentError, "Trigger '#{@trigger.name}' (ID: #{@trigger.id}) runs no workflow — it fires through its prompt template"
    end

    workflow = WorkflowRegistry.find!(@trigger.workflow_id)
    input = workflow.build_input!(@payload)
    plan = workflow.new.plan(input)
    raise Workflow::Plan::InvalidPlanError, "#{workflow.name}#plan returned #{plan.class}, not a Workflow::Plan" unless plan.is_a?(Workflow::Plan)

    run = WorkflowRun.new(workflow_id: workflow.workflow_id, trigger: @trigger, input: input.to_h, resolved: plan.resolved)
    session = @trigger.create_session!(prompt: plan.instructions, genesis: @genesis, workflow_run: run)

    Result.new(session: session, workflow_run: run.persisted? ? run : nil)
  end
end
