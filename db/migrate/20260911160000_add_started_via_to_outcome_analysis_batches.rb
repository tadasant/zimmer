# frozen_string_literal: true

# Who started an "Analyze All" batch.
#
# A batch can be started from two surfaces: the Analyze All button on /outcomes,
# and the `action_outcome_analysis` MCP tool. The Outcomes feature's premise is
# that nothing is analyzed implicitly, so a batch an agent started has to say so
# on the ledger rather than look like a human's click.
#
#   started_via            "web_ui" or "mcp" — OutcomeAnalysisBatch::STARTED_VIA.
#                          Existing rows are all web_ui: the button was the only
#                          way to start one.
#   started_by_session_id  the session whose MCP connection started the batch,
#                          when the connection names one. Null for a web-UI
#                          batch, and for an MCP client that is not a session.
#
# The partial unique index is the agent cap's "one at a time" rule, held by the
# database rather than by a check-then-insert: two MCP calls racing each other
# cannot both get a running batch.
class AddStartedViaToOutcomeAnalysisBatches < ActiveRecord::Migration[8.0]
  def change
    add_column :outcome_analysis_batches, :started_via, :string, null: false, default: "web_ui"
    add_reference :outcome_analysis_batches, :started_by_session,
                  foreign_key: { to_table: :sessions, on_delete: :nullify },
                  index: { where: "started_by_session_id IS NOT NULL" }

    add_index :outcome_analysis_batches, :started_via,
              unique: true,
              where: "status = 'running' AND started_via = 'mcp'",
              name: "index_outcome_analysis_batches_one_running_mcp"
  end
end
