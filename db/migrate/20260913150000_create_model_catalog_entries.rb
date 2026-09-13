# frozen_string_literal: true

# Models an operator added to a runtime's catalog at runtime (#85).
#
# ModelCatalog::MODELS stays the shipped baseline; these rows are appended to it,
# so a fresh install with an empty table offers exactly what it always did.
#
#   runtime         a ModelCatalog::MODELS key ("claude_code", "codex", "pi")
#   model_id        the id passed to the CLI's --model / -m, verbatim
#   label           what a picker shows; blank means the id
#   requires_oauth  the same flag the built-in entries carry
#   cli_listed      whether the installed CLI's own model list named the id when
#                   it was added: true, false, or NULL when the runtime has no
#                   list to check (Claude Code) or the check could not run
#   cli_version     the version of that CLI the check ran against
#   cli_note        the check's own sentence — why it is NULL, or what an
#                   unlisted id means for that runtime
#   added_via       "web_ui", "api" or "mcp"
class CreateModelCatalogEntries < ActiveRecord::Migration[8.0]
  def change
    create_table :model_catalog_entries do |t|
      t.string :runtime, null: false
      t.string :model_id, null: false
      t.string :label
      t.boolean :requires_oauth, null: false, default: false
      t.boolean :cli_listed
      t.string :cli_version
      t.text :cli_note
      t.string :added_via, null: false
      t.timestamps
    end

    add_index :model_catalog_entries, [ :runtime, :model_id ], unique: true
  end
end
