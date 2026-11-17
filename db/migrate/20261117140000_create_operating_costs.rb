# frozen_string_literal: true

# The all-in operating-cost ledger behind the Costs page: what running this
# deployment costs in real money, by functionality, vendor and agent root.
#
# Nine tables, one domain. Raw facts (observations, credit snapshots,
# subscriptions) are written through OperatingCosts::Recorder and never edited
# in place; the daily series and the monthly allocations are rebuilt from them
# (OperatingCosts::Ledger, OperatingCosts::Allocator), so either can be thrown
# away and recomputed. The taxonomy (functionalities, vendors, accounts) is
# deployment data: the repository ships none of it.
class CreateOperatingCosts < ActiveRecord::Migration[8.1]
  def change
    create_table :operating_cost_functionalities do |t|
      t.string :key, null: false
      t.string :name, null: false
      t.text :description
      t.jsonb :agent_roots, null: false, default: []
      t.jsonb :mcp_servers, null: false, default: []
      t.integer :position, null: false, default: 0
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_index :operating_cost_functionalities, :key, unique: true

    create_table :operating_cost_vendors do |t|
      t.string :key, null: false
      t.string :name, null: false
      t.string :category, null: false, default: "other"
      t.string :pricing_model, null: false, default: "usage"
      t.string :ingest_method, null: false, default: "manual"
      t.string :billing_url
      t.text :notes
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_index :operating_cost_vendors, :key, unique: true

    create_table :operating_cost_accounts do |t|
      t.references :vendor, null: false, foreign_key: { to_table: :operating_cost_vendors }
      t.references :functionality, foreign_key: { to_table: :operating_cost_functionalities, on_delete: :nullify }
      t.string :key, null: false
      t.string :label, null: false
      t.string :paid_by, null: false, default: "self"
      t.decimal :zimmer_share, precision: 5, scale: 4, null: false, default: 1
      t.string :allocation_rule, null: false, default: "unallocated"
      t.jsonb :allocation_config, null: false, default: {}
      t.string :derived_source
      t.string :environment
      t.string :external_ref
      t.text :notes
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_index :operating_cost_accounts, :key, unique: true
    add_index :operating_cost_accounts, :derived_source, unique: true

    create_table :operating_cost_subscriptions do |t|
      t.references :account, null: false, foreign_key: { to_table: :operating_cost_accounts, on_delete: :cascade }
      t.string :plan_name, null: false
      t.decimal :amount, precision: 14, scale: 4, null: false
      t.string :currency, null: false, default: "USD"
      t.decimal :amount_usd, precision: 14, scale: 4, null: false
      t.string :interval, null: false, default: "month"
      t.integer :quantity, null: false, default: 1
      t.decimal :included_usage_usd, precision: 14, scale: 4
      t.date :started_on, null: false
      t.date :ended_on
      t.date :renews_on
      t.boolean :auto_renew, null: false, default: true
      t.text :notes
      t.timestamps
    end
    add_index :operating_cost_subscriptions, [ :account_id, :plan_name, :started_on ], unique: true,
      name: "index_operating_cost_subscriptions_identity"

    create_table :operating_cost_observations do |t|
      t.references :account, null: false, foreign_key: { to_table: :operating_cost_accounts, on_delete: :cascade }
      t.string :metric, null: false
      t.date :as_of_date, null: false
      t.date :period_start, null: false
      t.date :period_end, null: false
      t.decimal :amount, precision: 14, scale: 4, null: false
      t.string :currency, null: false, default: "USD"
      t.decimal :amount_usd, precision: 14, scale: 4, null: false
      t.string :source, null: false
      t.string :confidence, null: false
      t.string :collector
      t.jsonb :raw_payload, null: false, default: {}
      t.text :evidence
      t.bigint :recorded_by_session_id
      t.timestamps
    end
    add_index :operating_cost_observations, [ :account_id, :metric, :as_of_date, :period_start, :source ], unique: true,
      name: "index_operating_cost_observations_identity"
    add_index :operating_cost_observations, :as_of_date

    create_table :operating_cost_credit_snapshots do |t|
      t.references :account, null: false, foreign_key: { to_table: :operating_cost_accounts, on_delete: :cascade }
      t.date :as_of_date, null: false
      t.decimal :balance, precision: 14, scale: 4, null: false
      t.string :currency, null: false, default: "USD"
      t.decimal :balance_usd, precision: 14, scale: 4, null: false
      t.string :kind, null: false, default: "prepaid"
      t.decimal :granted_total, precision: 14, scale: 4
      t.date :expires_on
      t.string :source, null: false
      t.text :evidence
      t.bigint :recorded_by_session_id
      t.timestamps
    end
    add_index :operating_cost_credit_snapshots, [ :account_id, :as_of_date, :source ], unique: true,
      name: "index_operating_cost_credit_snapshots_identity"

    create_table :operating_cost_daily_entries do |t|
      t.references :account, null: false, foreign_key: { to_table: :operating_cost_accounts, on_delete: :cascade }
      t.date :date, null: false
      t.decimal :amount_usd, precision: 14, scale: 4, null: false
      t.string :basis, null: false
      t.string :confidence, null: false
      t.string :source, null: false
      t.timestamps
    end
    add_index :operating_cost_daily_entries, [ :account_id, :date ], unique: true
    add_index :operating_cost_daily_entries, :date

    create_table :operating_cost_monthly_allocations do |t|
      t.references :account, null: false, foreign_key: { to_table: :operating_cost_accounts, on_delete: :cascade }
      t.references :functionality, foreign_key: { to_table: :operating_cost_functionalities, on_delete: :nullify }
      t.date :month, null: false
      t.string :agent_root
      t.decimal :amount_usd, precision: 14, scale: 4, null: false
      t.decimal :share, precision: 7, scale: 6, null: false
      t.string :allocation_method, null: false
      t.jsonb :basis_detail, null: false, default: {}
      t.datetime :computed_at, null: false
      t.timestamps
    end
    add_index :operating_cost_monthly_allocations, [ :month, :account_id ]

    create_table :operating_cost_collection_runs do |t|
      t.string :collector, null: false
      t.string :status, null: false
      t.datetime :started_at, null: false
      t.datetime :finished_at
      t.integer :rows_written, null: false, default: 0
      t.text :error
      t.bigint :session_id
      t.jsonb :details, null: false, default: {}
      t.timestamps
    end
    add_index :operating_cost_collection_runs, [ :collector, :started_at ]
  end
end
