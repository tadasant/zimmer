class AddFavoritedToSessions < ActiveRecord::Migration[8.0]
  def change
    add_column :sessions, :favorited, :boolean, default: false, null: false
    add_index :sessions, :favorited
  end
end
