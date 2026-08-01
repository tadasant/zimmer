# frozen_string_literal: true

# Repoints stored `catalog_skills` references from the old `pr` skill id to
# `open-pr`, the id the catalog registers instead.
#
# Sessions and triggers freeze their skill ids at creation time, so every row
# created before the rename still asks for `pr`. The runtime self-heals
# (AirPrepareService#scrubbed_catalog_skills for sessions,
# Trigger#heal_stale_catalog_skills! for triggers) — but a heal only *drops* the
# unknown id, which silently strips the PR workflow from long-lived sessions and
# from every future session a trigger spawns, and it only runs the next time that
# row is used. Renaming here preserves the intent instead of losing it, and does
# so for rows that may not be touched again for weeks.
#
# Deliberately narrow: this maps one known rename rather than pruning whatever
# the catalog happens not to resolve today. A migration must be deterministic,
# and the catalog is a runtime dependency that can resolve differently (or fail
# to resolve at all) at migration time — pruning against it could strip valid
# skills. General staleness stays the runtime heal's job.
class BackfillRenamedOpenPrSkillId < ActiveRecord::Migration[8.0]
  OLD_ID = "pr"
  NEW_ID = "open-pr"

  def up
    rename_catalog_skill(OLD_ID, NEW_ID)
  end

  # Reverts the mapping. This also repoints rows that only ever held `open-pr`,
  # which is inherent to reversing a rename: the two ids are indistinguishable
  # after the fact.
  def down
    rename_catalog_skill(NEW_ID, OLD_ID)
  end

  private

  # `quote` is reached through the connection rather than Migration's
  # method_missing, which would rewrite the first argument via proper_table_name
  # and wrap each call in its own say_with_time line.
  def rename_catalog_skill(from, to)
    quoted_from = connection.quote(from.to_json)
    quoted_to = connection.quote(to.to_json)
    quoted_match = connection.quote([ from ].to_json)

    %w[sessions triggers].each do |table|
      execute(<<~SQL.squish)
        UPDATE #{table} AS t
        SET catalog_skills = renamed.skills
        FROM (
          SELECT inner_t.id,
                 COALESCE(
                   (
                     SELECT jsonb_agg(deduped.skill ORDER BY deduped.position)
                     FROM (
                       SELECT CASE WHEN element.value = #{quoted_from}::jsonb
                                   THEN #{quoted_to}::jsonb
                                   ELSE element.value
                              END AS skill,
                              MIN(element.position) AS position
                       FROM jsonb_array_elements(inner_t.catalog_skills)
                         WITH ORDINALITY AS element(value, position)
                       GROUP BY 1
                     ) AS deduped
                   ),
                   '[]'::jsonb
                 ) AS skills
          FROM #{table} AS inner_t
          WHERE inner_t.catalog_skills @> #{quoted_match}::jsonb
        ) AS renamed
        WHERE t.id = renamed.id
      SQL
    end
  end
end
