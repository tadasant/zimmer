# frozen_string_literal: true

# Phase 1 of moving `sessions`' five queryable `json` columns to `jsonb` (#847).
#
# `sessions` carries the only `json` columns left in the schema; every JSON column
# added anywhere since 2025-12 is `jsonb`, including four on `sessions` itself
# (`custom_metadata`, `catalog_skills`, `catalog_hooks`, `catalog_plugins`). The
# split costs real things: `AtomicJsonMetadata` casts to jsonb and back on every
# atomic write because one of the two columns it merges is `json`, `metadata`
# cannot carry a GIN index so its ~25 `->>` predicates are served by six
# single-purpose expression indexes, and `json` has no equality operator — a
# latent `could not identify an equality operator for type json` waiting for the
# first `SELECT DISTINCT` over `sessions.*`.
#
# WHY A SHADOW COLUMN INSTEAD OF `ALTER COLUMN ... TYPE jsonb`
#
# `json` and `jsonb` are not binary-coercible, so an in-place type change rewrites
# the ENTIRE table under `ACCESS EXCLUSIVE` — including `transcript`, which
# `SessionContentSearch` puts at gigabytes. That lock is an outage. `ADD COLUMN`
# with no default is a catalog-only change in PG 11+, so this migration takes no
# meaningful lock at all. The values arrive afterwards, from the dual-write in
# `JsonbDualWrite` and the `BackfillSessionsJsonb` post-deploy task, and PR 2 cuts
# reads over and drops the originals under the two-deploy rule in AGENTS.md.
#
# `transcript` IS DELIBERATELY NOT HERE — DO NOT "FINISH THE JOB"
#
# It is the one column that makes the in-place route dangerous, and it is the one
# column that gains nothing from the move: a single opaque blob, never queried by
# key, routinely multiple megabytes. `jsonb` would cost MORE to write for a
# document that size, since it is parsed and re-encoded on every write rather than
# stored as the text it arrived as. If `transcript` ever moves it should move out
# of the row entirely (#714, transcript archives), not to another column type.
class AddJsonbShadowColumnsToSessions < ActiveRecord::Migration[8.0]
  COLUMNS = %i[config mcp_servers mcp_server_env mcp_server_headers metadata].freeze

  def change
    COLUMNS.each do |name|
      add_column :sessions, :"#{name}_jsonb", :jsonb, null: true
    end
  end
end
