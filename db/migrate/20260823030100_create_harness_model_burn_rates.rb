# frozen_string_literal: true

# The measured "$ per minute" of one harness + model combination.
#
# The scheduler needs to answer "what will admitting this session cost me over
# the next ten minutes?" before it admits it, and the only honest source for
# that is what the same kind of work has cost recently. Computing it on the
# scheduling hot path would mean an aggregate over millions of ledger rows every
# time a spot session tries to start, so BurnRateCalculator computes it on a
# cron and this table is what the gate and the Costs page read.
#
# One row per (harness, model). `harness` is the agent root — the same dimension
# the Costs tab breaks spend down by — because that is what predicts a session's
# spend shape: a router turn and a merge-gate turn cost very different money on
# the same model.
class CreateHarnessModelBurnRates < ActiveRecord::Migration[8.0]
  def change
    create_table :harness_model_burn_rates do |t|
      t.string :harness, null: false
      t.string :model, null: false
      t.float :usd_per_minute, null: false, default: 0.0
      t.float :sample_cost_usd, null: false, default: 0.0
      t.float :sample_minutes, null: false, default: 0.0
      t.integer :sample_session_count, null: false, default: 0
      t.datetime :sample_newest_at
      t.datetime :sample_oldest_at
      t.datetime :computed_at, null: false
      t.timestamps
    end

    add_index :harness_model_burn_rates, %i[harness model], unique: true
    add_index :harness_model_burn_rates, :usd_per_minute
  end
end
