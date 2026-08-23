# frozen_string_literal: true

# What one quota window is worth in dollars, estimated from what the deployment
# actually spent while filling it.
#
# Anthropic reports quota as a percentage and never as money, so "we are at 76%
# of the 5-hour window" cannot be compared against anything — not a reserve, not
# a burn rate, not a decision about whether one more session fits. The estimator
# is a ratio: Opus-denominated spend over the window divided by the pool's
# utilization of it gives the dollars a full window is worth.
#
# One row per window kind, holding the smoothed estimate and the observation it
# was last updated from, so the page can show its own provenance rather than an
# unattributable number.
class CreateQuotaCapacityEstimates < ActiveRecord::Migration[8.0]
  def change
    create_table :quota_capacity_estimates do |t|
      t.string :window_key, null: false
      t.float :capacity_usd
      t.float :observed_capacity_usd
      t.float :sample_cost_usd
      t.float :sample_utilization
      t.integer :observation_count, null: false, default: 0
      t.datetime :computed_at
      t.timestamps
    end

    add_index :quota_capacity_estimates, :window_key, unique: true
  end
end
