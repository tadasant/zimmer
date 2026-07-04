class AddTitleToSessions < ActiveRecord::Migration[8.0]
  def change
    add_column :sessions, :title, :string
  end
end
