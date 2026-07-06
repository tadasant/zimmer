class AddResuscitateArchivedToTriggers < ActiveRecord::Migration[8.0]
  def change
    add_column :triggers, :resuscitate_archived, :boolean, default: false, null: false
  end
end
