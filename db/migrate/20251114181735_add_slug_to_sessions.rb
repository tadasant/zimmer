class AddSlugToSessions < ActiveRecord::Migration[8.0]
  def change
    add_column :sessions, :slug, :string
    add_index :sessions, :slug, unique: true
  end
end
