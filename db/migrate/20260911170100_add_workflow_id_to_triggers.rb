# frozen_string_literal: true

# Phase 0 of Workflow as a primitive (#18): a trigger may name a workflow instead
# of carrying a prompt template.
#
# Additive, and safe across the deploy's overlap window. Every existing row has a
# template and no workflow, which satisfies the new check constraint as it
# stands; the containers still serving during cutover write a template on every
# path they have, which satisfies it too. Relaxing `prompt_template`'s NOT NULL
# is what lets a workflow trigger carry none — and the check constraint is what
# keeps that relaxation from admitting a row with neither.
class AddWorkflowIdToTriggers < ActiveRecord::Migration[8.0]
  def change
    add_column :triggers, :workflow_id, :string
    change_column_null :triggers, :prompt_template, true
    add_check_constraint :triggers, "num_nonnulls(prompt_template, workflow_id) = 1",
      name: "triggers_prompt_template_xor_workflow_id"
    # A workflow trigger never reuses a session (Trigger#validate_workflow says
    # why), held here too so that no write that skips the model can make one.
    add_check_constraint :triggers, "workflow_id IS NULL OR reuse_session = false",
      name: "triggers_workflow_trigger_never_reuses_session"
  end
end
