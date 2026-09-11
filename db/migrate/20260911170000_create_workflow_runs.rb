# frozen_string_literal: true

# Phase 0 of Workflow as a primitive (#18): the orchestrator-owned record of a
# workflow run.
#
# One row per session a workflow started — which workflow, fired from which
# trigger, with what validated input, resolving to which trusted identifiers.
# `resolved` is the column the table exists for: the identifiers a run may act on,
# written once by the orchestrator at plan time and never by anything the agent
# says. It is deliberately not `sessions.metadata`, which dozens of code paths
# write and which is `json`, not `jsonb`.
#
# The foreign keys are chosen so that this table never blocks anything else's
# cleanup: a session purge cascades its run away, and a trigger cleanup leaves
# the run (the audit record) and forgets which trigger it was.
class CreateWorkflowRuns < ActiveRecord::Migration[8.0]
  def change
    create_table :workflow_runs do |t|
      t.references :session, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      # NULL for a run no trigger fired. Nothing starts one of those yet; the
      # column is nullable now so that a manual or API run later needs no migration.
      t.references :trigger, null: true, foreign_key: { on_delete: :nullify }
      t.string :workflow_id, null: false
      t.jsonb :input, null: false, default: {}
      t.jsonb :resolved, null: false, default: {}

      t.timestamps
    end

    add_index :workflow_runs, :workflow_id
  end
end
