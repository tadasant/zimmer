# frozen_string_literal: true

# A row's declaration that its issue stays open by design after a merged PR. See
# WorkBacklogItem::CONTINUATIONS.
class AddContinuationToWorkBacklogItems < ActiveRecord::Migration[8.1]
  def change
    add_column :work_backlog_items, :continuation, :string
  end
end
