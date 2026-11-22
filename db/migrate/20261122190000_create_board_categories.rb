# frozen_string_literal: true

# Your board v2's categories: flat, manually managed groups a session is dragged
# into. See BoardCategory.
#
# A new table and a new column rather than the `categories` table and
# `sessions.category_id` the old auto-categorizer left behind. Those are phase 1
# of a two-phase drop (tadasant/zimmer#16) — ignored by the models and due to be
# dropped — and they still hold the auto-categorizer's assignments, which this
# feature must not resurrect: every row here is one a person made.
class CreateBoardCategories < ActiveRecord::Migration[8.1]
  def change
    create_table :board_categories do |t|
      t.string :name, null: false
      t.integer :position, null: false, default: 0
      t.boolean :collapsed, null: false, default: false
      t.string :visibility, null: false, default: "visible"
      t.datetime :snoozed_until
      t.timestamps
    end
    add_index :board_categories, :position

    add_reference :sessions, :board_category, foreign_key: { on_delete: :nullify }, index: true
  end
end
