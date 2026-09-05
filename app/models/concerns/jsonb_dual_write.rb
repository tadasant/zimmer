# frozen_string_literal: true

# Dual-write scaffolding for the `json` → `jsonb` conversion of five `sessions`
# columns (#847). **Temporary by construction**: nothing reads a `_jsonb` column
# yet, and PR 2 deletes this file whole once the `BackfillSessionsJsonb` run reads
# `succeeded` in production and the readers have been cut over.
#
# WHY THE COLUMNS ARE SHADOWED RATHER THAN RETYPED IN PLACE: see the migration,
# `20260905193000_add_jsonb_shadow_columns_to_sessions.rb`. Short version — the
# in-place `ALTER COLUMN ... TYPE jsonb` rewrites the whole table, `transcript`
# included, under `ACCESS EXCLUSIVE`.
#
# THE FAILURE MODE THIS IS DESIGNED AGAINST IS SILENT. A key that reaches
# `metadata` but not `metadata_jsonb` breaks NOTHING today — nothing reads the
# shadow — and becomes data loss the moment PR 2 swaps the readers over. There is
# no symptom to watch for in the meantime, so the coverage cannot be a list of
# call sites somebody remembered; it has to be structural. Three code paths write
# these columns, and each gets a mechanism rather than an edit:
#
#   1. **Ordinary model writes** — `Session.new`, `create!`, `update!`, `save`,
#      and AASM's own persistence. They run callbacks, so the `before_save`
#      below mirrors whatever the save is about to write.
#
#   2. **The atomic merges in `AtomicJsonMetadata`** — raw UPDATEs issued around
#      the model, which reach no callback at all. That concern asks `twin_for`
#      and adds a second SET to the same statement.
#
#   3. **`update_column` / `update_columns`** — which skip callbacks by design,
#      and so skip (1). This is the path that actually bit during development:
#      `Session#set_default_title` writes `metadata` this way on every untitled
#      session and `#touch_user_view!` does it on every page view, so the two
#      hottest raw writers in the app were both silently one-sided. Rather than
#      patch those two call sites and leave the next one to chance,
#      `update_columns` is overridden below to expand a converted column into
#      itself and its shadow. `update_column` delegates to it, so both are
#      covered, and a call site added tomorrow is covered without knowing this
#      file exists.
#
# What is deliberately NOT covered is `update_all` and hand-written SQL, which
# are relation- and connection-level and cannot be reached from here. No call
# site writes a converted column either way today — `BackfillSessionsJsonb` uses
# `update_all` precisely BECAUSE it is writing the shadow directly — and
# `test/models/concerns/jsonb_dual_write_test.rb` drives a whole session
# lifecycle to catch a writer nobody enumerated.
#
# The shadow columns are nullable with no default, deliberately: NULL is how the
# backfill tells "not copied yet" from "copied, and genuinely empty". PR 2 puts
# `metadata`'s `default: {}` back when it does the rename.
module JsonbDualWrite
  extend ActiveSupport::Concern

  # `<name>` is the live `json` column that everything still reads; `<name>_jsonb`
  # is its shadow. `transcript` is NOT in this list and is not being converted.
  # `custom_metadata` is not either — it has been `jsonb` from the start, which is
  # the whole reason `AtomicJsonMetadata` carries a per-column cast today.
  COLUMNS = %w[config mcp_servers mcp_server_env mcp_server_headers metadata].freeze

  # The shadow column for `name` on `model`, or nil if `name` is not being
  # converted there.
  #
  # nil rather than an exception, because the callers legitimately ask about
  # columns that have no twin: `AtomicJsonMetadata` merges `custom_metadata` as
  # well as `metadata`, and only one of the two is shadowed. The `columns_hash`
  # check keeps a deploy that runs this code before the migration — or a model
  # that never got the columns — from generating SQL naming a column that is not
  # there.
  #
  # The `model < JsonbDualWrite` check matters because `COLUMNS` holds generic
  # names. `AtomicJsonMetadata` is a standalone concern with nothing tying it to
  # `Session`, so a future model that included it and happened to have both
  # `metadata` and `metadata_jsonb` would otherwise get shadow SQL it never asked
  # for.
  def self.twin_for(model, name)
    return nil unless model < JsonbDualWrite
    return nil unless COLUMNS.include?(name.to_s)

    twin = "#{name}_jsonb"
    twin if model.columns_hash.key?(twin)
  end

  included do
    before_save :mirror_json_columns_to_jsonb
  end

  # Writer (3) from the header comment. `update_column(name, value)` is
  # `update_columns(name => value)` in ActiveRecord, so overriding this one method
  # covers both.
  #
  # An override rather than a differently-named helper on purpose: a helper only
  # protects the call sites that remember to use it, and the writers this has to
  # cover are ones nobody thinks about — a flag set in an `after_create`, a
  # last-viewed timestamp. The expansion is a no-op for every other column, which
  # is every other call site in the app.
  def update_columns(attributes)
    expanded = attributes.each_with_object({}) do |(name, value), out|
      out[name] = value
      # Resolved through `attribute_aliases` because Rails resolves them AFTER
      # this point, in its own `update_columns`. Session declares no alias today;
      # the premise of the override is that a call site added tomorrow is covered
      # without knowing this file exists, and an alias added tomorrow would
      # otherwise defeat it silently.
      twin = JsonbDualWrite.twin_for(self.class, self.class.attribute_aliases[name.to_s] || name)
      out[twin] = value if twin
    end

    super(expanded)
  end

  private

  # Writer (1). Copy every converted column this save is about to write into its
  # shadow.
  #
  # `new_record?` short-circuits the dirty check on create: an INSERT writes every
  # column whether or not the caller assigned it, and a column filled from its
  # schema default is exactly the case a dirty check is least reliable about.
  #
  # Unguarded by `has_attribute?` on purpose. A partially-selected record —
  # `Session.select(:id, :metadata)` — carries no shadow attribute, and
  # `write_attribute` DEFINES one rather than raising, so the shadow travels with
  # the save instead of being left behind. Verified against this Rails version
  # rather than assumed; a guard here would only skip a write that works.
  def mirror_json_columns_to_jsonb
    JsonbDualWrite::COLUMNS.each do |name|
      twin = JsonbDualWrite.twin_for(self.class, name)
      next if twin.nil?
      next unless new_record? || will_save_change_to_attribute?(name)

      write_attribute(twin, read_attribute(name))
    end
  end
end
