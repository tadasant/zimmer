# frozen_string_literal: true

# One-time backfill for the `pr` → `open-pr` skill rename.
#
# AirPrepareService now persists its stale-skill self-heal, so any affected
# session heals itself on its next resume — but healing on resume still costs one
# #eng-alerts notice per session. Five non-archived sessions (31, 108, 202, 239,
# 280) plus a long tail of archived ones carry the dead `pr` id; clearing it here
# means those notices never fire at all.
#
# `pr` is hardcoded rather than scrubbed against the live catalog on purpose: a
# migration must be deterministic and must not depend on AIR resolving the
# catalog at deploy time. `pr` is the only stale id present anywhere in the
# sessions table, and it is dead catalog-wide (renamed to `open-pr`). The rows
# are only touched, never rewritten wholesale — the id is removed and the rest of
# each list is preserved in order.
#
# Not reversible: re-adding a catalog id that no longer exists would only
# re-create the bug.
class RemoveStalePrSkillFromSessions < ActiveRecord::Migration[8.1]
  def up
    execute(<<~SQL)
      UPDATE sessions
      SET catalog_skills = (
        SELECT COALESCE(jsonb_agg(skill ORDER BY ord), '[]'::jsonb)
        FROM jsonb_array_elements(catalog_skills) WITH ORDINALITY AS t(skill, ord)
        WHERE skill <> '"pr"'::jsonb
      )
      WHERE catalog_skills @> '["pr"]'::jsonb
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
