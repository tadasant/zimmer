# Where queue recovery mode keeps the part of its state that a human reads:
# when it was entered, by whom, why, and when the TTL backstop auto-exits.
#
# The halt ITSELF is not stored here — that is GoodJob's own pause feature, in
# `good_job_settings`, which is what the worker enforces at dequeue. This column
# is Zimmer's metadata about the halt, and QueueRecoveryMode keeps the two in
# step. One JSONB map rather than four columns, matching `extension_states` on
# the same table.
class AddQueueRecoveryModeToAppSettings < ActiveRecord::Migration[8.0]
  def change
    add_column :app_settings, :queue_recovery_mode, :jsonb, default: {}, null: false
  end
end
