class CreateCategoriesAndAddCategoryToSessions < ActiveRecord::Migration[8.1]
  def change
    create_table :categories do |t|
      t.string :name, null: false
      # position has no DB default: the model assigns the next position on create
      # (a default would make the "auto-increment unless explicitly set" logic ambiguous).
      t.integer :position, null: false

      t.timestamps
    end

    add_index :categories, :position

    # Nullable category_id: a NULL value means the session is "Uncategorized".
    add_reference :sessions, :category, null: true, foreign_key: { on_delete: :nullify }
  end
end
