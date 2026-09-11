# frozen_string_literal: true

# What a key opens (tadasant/zimmer#175). Every key that existed before this
# column opened the whole REST API and the MCP endpoint, and `api` keeps meaning
# exactly that — so the default backfills every existing row without changing
# what any of them can do.
#
# The one other value, `quick_router`, is the browser extension's credential: it
# is accepted by `POST /api/v1/quick_router` and by nothing else. A key sitting in
# a browser's extension storage on a machine that browses the open web must not
# be a key that can read every transcript in the instance, and a column the auth
# check compares on is how that is made true by construction rather than by
# asking the holder to be careful.
#
# `if_not_exists` because databases exist that already have this column and no
# record of this migration: they were built by loading a `db/schema.rb` that
# carried the column under a single `20260912120000` row standing in for the two
# migrations that both claimed that version (#1163).
class AddGrantToApiKeys < ActiveRecord::Migration[8.1]
  def change
    add_column :api_keys, :grant, :string, null: false, default: "api", if_not_exists: true
  end
end
