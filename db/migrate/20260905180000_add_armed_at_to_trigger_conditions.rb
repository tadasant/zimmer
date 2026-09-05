# frozen_string_literal: true

# `armed_at` is the instant a schedule condition's configured slot started
# counting — the anchor TriggerCondition#armed_before? measures a never-fired
# `days`/`weeks` schedule's first fire from.
#
# Existing rows are backfilled from `created_at`, which is exactly what
# #armed_before? read before this column existed, so the deploy changes no live
# schedule's next fire.
class AddArmedAtToTriggerConditions < ActiveRecord::Migration[8.0]
  def up
    add_column :trigger_conditions, :armed_at, :datetime

    # Backfill in one statement: the table is small (one row per condition, a few
    # hundred at most) and every row needs the same value it already carries.
    execute "UPDATE trigger_conditions SET armed_at = created_at WHERE armed_at IS NULL"
  end

  def down
    remove_column :trigger_conditions, :armed_at
  end
end
