# frozen_string_literal: true

# When WorkBacklog::DecisionDigest last delivered this row's owed decision to a
# person. See WorkBacklogItem::HOLD_DURATION.
class AddHoldDigestedAtToWorkBacklogItems < ActiveRecord::Migration[8.1]
  def change
    add_column :work_backlog_items, :hold_digested_at, :datetime
  end
end
