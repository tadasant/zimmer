class AddCatalogSkillsToSessions < ActiveRecord::Migration[8.0]
  def change
    add_column :sessions, :catalog_skills, :jsonb, default: []
  end
end
