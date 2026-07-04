class AddTrashAfterToSessions < ActiveRecord::Migration[8.0]
  def change
    add_column :sessions, :trash_after, :datetime
    add_index :sessions, :trash_after, where: "trash_after IS NOT NULL"
  end
end
