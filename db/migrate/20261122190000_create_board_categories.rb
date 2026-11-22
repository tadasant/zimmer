# frozen_string_literal: true

# Your board v2's categories: flat, manually managed groups a session is dragged
# into. See BoardCategory.
#
# A new table and a new column rather than the `categories` table and
# `sessions.category_id` the old auto-categorizer left behind. Those are phase 1
# of a two-phase drop (tadasant/zimmer#16) — ignored by the models and due to be
# dropped — and they still hold the auto-categorizer's assignments, which this
# feature must not resurrect: every row here is one a person made.
#
# Outside a transaction so the index on `sessions` builds concurrently and the
# foreign key is added unvalidated and then validated: `sessions` takes a write on
# every heartbeat and status change, and the old containers keep serving while
# this runs. Each step is guarded so a run interrupted halfway can be re-run.
class CreateBoardCategories < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    unless table_exists?(:board_categories)
      create_table :board_categories do |t|
        t.string :name, null: false
        t.integer :position, null: false, default: 0
        t.boolean :collapsed, null: false, default: false
        t.string :visibility, null: false, default: "visible"
        t.datetime :snoozed_until
        t.timestamps
      end
      add_index :board_categories, :position
    end

    add_column :sessions, :board_category_id, :bigint unless column_exists?(:sessions, :board_category_id)
    add_index :sessions, :board_category_id, algorithm: :concurrently, if_not_exists: true
    unless foreign_key_exists?(:sessions, :board_categories)
      add_foreign_key :sessions, :board_categories, on_delete: :nullify, validate: false
    end
    validate_foreign_key :sessions, :board_categories
  end

  def down
    remove_foreign_key :sessions, :board_categories, if_exists: true
    remove_index :sessions, :board_category_id, algorithm: :concurrently, if_exists: true
    remove_column :sessions, :board_category_id, if_exists: true
    drop_table :board_categories, if_exists: true
  end
end
