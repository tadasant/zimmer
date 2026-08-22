# frozen_string_literal: true

# One row per (session, experimental setting): what the setting was when the
# session first ran, and what it was the last time we looked.
#
# The cohort columns are booleans rather than a single "was it on" flag because a
# setting toggled mid-session puts that session in neither cohort, and averaging
# it into one of them is how a crude A/B test quietly lies. Start and end are
# stored separately so the disagreement is visible and can be bucketed out.
class CreateSessionExperimentalFlags < ActiveRecord::Migration[8.1]
  def change
    create_table :session_experimental_flags do |t|
      t.references :session, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.string :setting_key, null: false
      t.boolean :value_at_start
      t.boolean :value_at_end
      # "observed" — read off the live setting while the session ran.
      # "backfilled" — inferred from the session's timestamps against the date
      # the setting landed, for history that predates this table.
      t.string :source, null: false, default: "observed"
      t.datetime :first_observed_at
      t.datetime :last_observed_at

      t.timestamps
    end

    add_index :session_experimental_flags, [ :session_id, :setting_key ], unique: true,
      name: "index_session_experimental_flags_on_session_and_key"
    # The cohort rollup joins in on `session_id` and is served by the unique index
    # above. The only query that filters on `setting_key` alone is the provenance
    # count, which groups by `source` — so that is the pair worth covering.
    add_index :session_experimental_flags, [ :setting_key, :source ],
      name: "index_session_experimental_flags_on_key_and_source"
  end
end
