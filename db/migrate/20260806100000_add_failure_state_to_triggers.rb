# frozen_string_literal: true

# A one-time scheduled wake whose fire raises is no longer destroyed — it is
# marked failed and left in place so the user can see what happened and re-arm
# it. These two columns carry the evidence the tombstone exists to preserve.
class AddFailureStateToTriggers < ActiveRecord::Migration[8.0]
  def change
    add_column :triggers, :failed_at, :datetime
    add_column :triggers, :last_error, :text
  end
end
