class AddCatalogSkillsToTriggers < ActiveRecord::Migration[8.0]
  def change
    add_column :triggers, :catalog_skills, :jsonb, default: [], null: false
  end
end
