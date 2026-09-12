# frozen_string_literal: true

# Phase 2 of moving `sessions`' five queryable `json` columns to `jsonb` (#847).
# `20260905193000_add_jsonb_shadow_columns_to_sessions` was phase 1.
#
# This is the contract half of an expand-and-contract. #1018 added a
# `<name>_jsonb` shadow beside each of `config`, `mcp_servers`, `mcp_server_env`,
# `mcp_server_headers` and `metadata`, wrote both on every path, and backfilled
# the rows that predated the shadows from a post-deploy task. This migration
# gives the shadow the original's NAME, so every reader in the app — the
# attribute, the ~25 `metadata ->> 'key'` predicates, the expression indexes —
# lands on `jsonb` without one call site changing.
#
# `transcript` IS DELIBERATELY NOT HERE — DO NOT "FINISH THE JOB". It has no
# shadow because it is the one column that makes the in-place route dangerous and
# the one column that gains nothing: a single opaque blob, never queried by key,
# routinely multiple megabytes, which `jsonb` would cost MORE to write. If it
# moves it should move out of the row entirely (#714). The long version is in the
# phase-1 migration's comment.
#
# WHY NO OLD CONTAINER IS STRANDED
#
# kamal-proxy health-gates the cutover, so for the length of the swap window the
# containers built from #1018's image are serving against this schema. Every name
# they compiled against still resolves, and resolves to the right data:
#
#   * They read and write `config` / `metadata` / … — still there, now `jsonb`,
#     holding the value the dual-write and the convergence below put in it.
#     Active Record casts `json` and `jsonb` to the same Ruby Hash, and an
#     `OID::Json` attribute round-trips through a `jsonb` column unchanged: the
#     wire format is text either way, and `json` → `jsonb` is an ASSIGNMENT cast
#     in PostgreSQL, so even `AtomicJsonMetadata`'s `SET metadata = (…)::json`
#     — the cast this whole issue exists to delete — lands in the retyped column
#     without complaint.
#   * They write `<name>_jsonb` from three places (the `before_save`, the
#     `update_columns` override, and the second SET in the atomic merge), and
#     `columns_hash` was cached at boot so they will do it whether or not the
#     column is still there. That is why the shadows are RE-ADDED, empty, rather
#     than dropped: without them every save from an old container would be a
#     `PG::UndefinedColumn`. Nothing reads them, in either image.
#
# WHY THE ORIGINALS ARE RENAMED ASIDE RATHER THAN DROPPED
#
# Dropping them here would be a single-phase drop — no image ever shipped with
# them in `ignored_columns`, so the annotation that shape calls for would be a
# claim about a deploy that never happened. Renaming them to `<name>_json_legacy`
# retires the name without destroying the data, this image is the one that leaves
# all ten dead names unread and unwritten, and the follow-up PR drops all ten
# under a `two-phase-drop` annotation that is true. It also makes this migration
# genuinely reversible: `down` puts the originals back, values and all.
#
# COST, AND WHY IT IS SAFE TO TAKE UNDER THE LOCK
#
# Everything here is catalog-only (`RENAME COLUMN`, `ADD COLUMN` with no default,
# `SET DEFAULT`) except the convergence UPDATE and the eight index rebuilds.
# The whole of it runs in one transaction, holding `ACCESS EXCLUSIVE` on
# `sessions` from the explicit `LOCK TABLE` that opens `up` to the commit.
# `sessions` is ~15k rows — `BackfillSessionsJsonb` copied 15,005 — and the heap
# scan does not touch `transcript`, which is TOASTed out of line. Seconds at the
# outside. The hazard that remains is the one every migration against this table
# carries: ACCESS EXCLUSIVE has to be GRANTED, and a `SessionContentSearch` read
# holding a share lock (`MAX_TIMEOUT_MS` is 120_000) makes this wait and queues
# everything behind it. No migration in this repo sets a `lock_timeout`, and
# introducing that pattern belongs in a PR about how the repo migrates.
#
# expand-contract: contract of #1018
class SwapSessionsJsonbShadowsIntoPlace < ActiveRecord::Migration[8.0]
  COLUMNS = %i[config mcp_servers mcp_server_env mcp_server_headers metadata].freeze

  # The expression and partial indexes that name one of the converted columns.
  # `RENAME COLUMN` carries an index along with the column it indexes, so without
  # this the originals would take all eight names with them into
  # `<name>_json_legacy` and the recreated ones would collide. They are dropped
  # and rebuilt rather than renamed because an index on a dead column indexes
  # nothing anybody will ever query.
  #
  # `->>` means the same thing on `jsonb` as on `json`, so every definition below
  # is the one already in `db/schema.rb`, rebuilt verbatim against the retyped
  # column. Replacing the `metadata` ones with a single
  # `USING gin (metadata jsonb_path_ops)` is what the conversion makes possible
  # and is deliberately NOT done here — #847 calls it a separate, later call, and
  # folding it in would double the surface of this migration for no extra safety.
  INDEXES = [
    { name: "index_sessions_on_config_model", expression: "((config ->> 'model'::text))" },
    { name: "index_sessions_on_agent_root_key", expression: "((metadata ->> 'agent_root_key'::text))" },
    { name: "index_sessions_on_trigger_id", expression: "((metadata ->> 'trigger_id'::text))",
      where: "((metadata ->> 'trigger_id'::text) IS NOT NULL)" },
    { name: "index_sessions_on_status_clone_path_expression", expression: "status, ((metadata ->> 'clone_path'::text))",
      where: "((metadata ->> 'clone_path'::text) IS NOT NULL)" },
    { name: "index_sessions_on_archived_stale_clone_candidates", expression: "status, archived_at, id",
      where: "((trash_after IS NULL) AND (archived_at IS NOT NULL) AND ((metadata ->> 'clone_path'::text) IS NOT NULL))" },
    { name: "index_sessions_on_status_trash_after_with_clone_path", expression: "status, trash_after",
      where: "((metadata ->> 'clone_path'::text) IS NOT NULL)" },
    { name: "index_sessions_on_failed_stale_clone_candidates", expression: "status, updated_at, id",
      where: "((metadata ->> 'clone_path'::text) IS NOT NULL)" },
    { name: "index_sessions_on_legacy_archived_stale_clone_candidates", expression: "status, updated_at, id",
      where: "((trash_after IS NULL) AND (archived_at IS NULL) AND ((metadata ->> 'clone_path'::text) IS NOT NULL))" }
  ].freeze

  def up
    # Taken explicitly, and BEFORE the convergence rather than as a side effect of
    # the first `rename_column`. Two reasons, and the first is a correctness bug
    # this migration had without it: an `UPDATE` on its own takes only
    # `ROW EXCLUSIVE`, so a writer reaching a converted column outside the model
    # — `update_all`, hand-written SQL, the two paths `JsonbDualWrite` could never
    # intercept — could commit a one-sided write in the gap between `converge!`
    # returning and the first DDL statement asking for the upgrade, and the rename
    # would promote that stale shadow. The window is a few round-trips wide and no
    # call site in the app writes these columns that way today, which is exactly
    # the kind of "nothing can reach it" that stops being true without anyone
    # noticing. Second, taking the strongest lock up front rather than upgrading
    # to it mid-transaction removes the lock-upgrade deadlock this would otherwise
    # be shaped like. It costs the duration of one bounded `UPDATE` on a ~15k-row
    # table, inside a transaction that is about to hold the same lock anyway.
    execute "LOCK TABLE sessions IN ACCESS EXCLUSIVE MODE"

    converge!

    drop_converted_indexes!

    COLUMNS.each do |name|
      rename_column :sessions, name, :"#{name}_json_legacy"
      rename_column :sessions, :"#{name}_jsonb", name
      # Re-added empty, for #1018's image to write into during the swap window.
      add_column :sessions, :"#{name}_jsonb", :jsonb, null: true
    end

    # `metadata` carried `default: {}` and the shadow deliberately did not — NULL
    # was how `BackfillSessionsJsonb` told "not copied yet" from "copied, and
    # genuinely empty". The distinction has done its job; put the default back on
    # the column that is now `metadata`, and take it off the dead one.
    change_column_default :sessions, :metadata, from: nil, to: {}
    change_column_default :sessions, :metadata_json_legacy, from: {}, to: nil

    create_converted_indexes!
  end

  def down
    drop_converted_indexes!

    COLUMNS.each do |name|
      remove_column :sessions, :"#{name}_jsonb"
      rename_column :sessions, name, :"#{name}_jsonb"
      rename_column :sessions, :"#{name}_json_legacy", name
    end

    change_column_default :sessions, :metadata, from: nil, to: {}
    change_column_default :sessions, :metadata_jsonb, from: {}, to: nil

    create_converted_indexes!
  end

  private

  # The one thing `BackfillSessionsJsonb`'s `succeeded` does NOT prove. That task
  # ran once, on 2026-09-06, so any row that diverged afterwards — a writer
  # reaching `metadata` through `update_all` or hand-written SQL, which a model
  # concern cannot intercept — would be promoted silently by the rename below.
  # #1018 said in as many words that this PR had to re-check the predicate rather
  # than trust that run, and this deployment offers no shell to check it from, so
  # the check is the repair: behind the explicit `LOCK TABLE` in `up` no writer
  # can race it, and afterwards every shadow equals its source by construction
  # rather than by argument. The lock is taken in `up` rather than here precisely
  # so that claim is true of this method — see the comment on it.
  #
  # `IS DISTINCT FROM`, so a genuinely NULL source is left NULL rather than
  # written — `NULL IS DISTINCT FROM NULL` is false.
  def converge!
    predicate = COLUMNS.map { |name| "(#{name}_jsonb IS DISTINCT FROM #{name}::jsonb)" }.join(" OR ")
    assignments = COLUMNS.map { |name| "#{name}_jsonb = #{name}::jsonb" }.join(", ")

    # No `updated_at` bump: this changes nothing anybody can see, and touching it
    # would reorder every list in the UI.
    converged = execute(<<~SQL.squish).cmd_tuples
      UPDATE sessions SET #{assignments} WHERE #{predicate}
    SQL

    say "converged #{converged} row#{'s' unless converged == 1} whose jsonb shadow had drifted since the backfill"
  end

  def drop_converted_indexes!
    INDEXES.each { |index| remove_index :sessions, name: index[:name] }
  end

  def create_converted_indexes!
    INDEXES.each do |index|
      add_index :sessions, index[:expression], name: index[:name], where: index[:where]
    end
  end
end
