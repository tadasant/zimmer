class AddFrozenToCategories < ActiveRecord::Migration[8.0]
  def change
    # A frozen category is excluded from every bulk "refresh / recover all sessions"
    # flow, so its sessions are left untouched (e.g. a "Backlog" the operator parks
    # work in). NOT NULL with a false default keeps existing categories unfrozen.
    #
    # The column is named +is_frozen+ rather than +frozen+ because +frozen?+ is a
    # reserved ActiveRecord/Object method — a +frozen+ column raises
    # ActiveRecord::DangerousAttributeError and the model fails to load.
    add_column :categories, :is_frozen, :boolean, null: false, default: false
  end
end
