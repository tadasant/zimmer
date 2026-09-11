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
class AddGrantToApiKeys < ActiveRecord::Migration[8.1]
  def change
    add_column :api_keys, :grant, :string, null: false, default: "api"
  end
end
