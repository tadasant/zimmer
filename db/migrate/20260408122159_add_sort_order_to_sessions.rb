class AddSortOrderToSessions < ActiveRecord::Migration[8.0]
  def change
    add_column :sessions, :sort_order, :integer, default: 0, null: false
    add_index :sessions, :sort_order
  end
end
