# Persists where the "Uncategorized" dashboard section sits in the category stack.
# Uncategorized is the category_id = nil bucket, so it has no Category.position to
# ride on — its slot is stored here on the singleton AppSetting row. Defaults to 0
# (top), which preserves the historical "Uncategorized always first" behavior.
class AddUncategorizedPositionToAppSettings < ActiveRecord::Migration[8.0]
  def change
    add_column :app_settings, :uncategorized_position, :integer, null: false, default: 0
  end
end
