# frozen_string_literal: true

# Per-agent-root persistent data: one generic document table, namespaced by
# agent root, reached through the opt-in `root_data` MCP tool group.
#
# ONE TABLE, NOT A SCHEMA OR A ROLE PER ROOT. A root gets "its own tables" by
# declaring collections in the catalog, never by Zimmer running DDL at runtime:
# the production Postgres is a single small node with a fixed connection budget
# (config/connection_budget.rb), and every table this app has is in db/schema.rb
# so `db:schema:verify` stays truthful in every environment (zimmer#780).
#
# The principle is work_backlog_items': the columns are what is queried, `data`
# is the rest. A collection's shape lives in the catalog as a JSON Schema and is
# checked on write; it is never a column.
class CreateAgentRootRecords < ActiveRecord::Migration[8.1]
  def change
    create_table :agent_root_records do |t|
      # Resolved server-side from the calling session's agent root — never a tool
      # argument. See RootData::Namespace.
      t.string :namespace, null: false
      t.string :collection, null: false

      # Optional. A keyed record is upserted by `put_root_record`; a keyless one
      # is appended. Unique only where present, so appends never collide.
      t.string :key

      t.jsonb :data, null: false, default: {}

      # The serialized size of `data`, stored so the caps and the usage counters
      # never have to re-measure a row to subtract it.
      t.integer :data_bytes, null: false, default: 0

      # Fixed when the row is written, from the collection's `retention_days` as
      # declared at that moment. The retention sweep reads only this column, so a
      # stale or changed catalog cannot reach back and delete stored rows.
      t.datetime :expires_at

      # The session that last wrote the row, stamped from the MCP connection.
      # Provenance, not authorization — the same caveat as gate_decisions.
      t.references :writing_session, foreign_key: { to_table: :sessions, on_delete: :nullify }, index: true

      t.timestamps
    end

    add_index :agent_root_records, [ :namespace, :collection, :key ], unique: true, where: "key IS NOT NULL",
              name: "index_agent_root_records_on_namespace_collection_key"
    add_index :agent_root_records, [ :namespace, :collection, :created_at ],
              name: "index_agent_root_records_on_namespace_collection_created"
    add_index :agent_root_records, :data, using: :gin, opclass: :jsonb_path_ops,
              name: "index_agent_root_records_on_data"
    # The retention sweep's selector: `expires_at < now() ORDER BY expires_at`.
    # Partial, because a collection with no retention writes NULL and the sweep
    # never needs to look at those rows.
    add_index :agent_root_records, [ :expires_at, :id ], where: "expires_at IS NOT NULL",
              name: "index_agent_root_records_on_expiry"

    # The cheap counter behind the caps and the usage report. One row per
    # (namespace, collection), updated in the same transaction as every write,
    # under a row lock — which also serializes writers to one collection, so the
    # row cap and the rate limit cannot be raced past.
    create_table :agent_root_record_counters do |t|
      t.string :namespace, null: false
      t.string :collection, null: false
      t.integer :records_count, null: false, default: 0
      t.bigint :data_bytes, null: false, default: 0

      # A fixed one-minute window for the write-rate limit.
      t.datetime :window_started_at
      t.integer :window_writes, null: false, default: 0

      t.datetime :last_written_at

      t.timestamps
    end

    add_index :agent_root_record_counters, [ :namespace, :collection ], unique: true,
              name: "index_agent_root_record_counters_on_namespace_collection"
  end
end
