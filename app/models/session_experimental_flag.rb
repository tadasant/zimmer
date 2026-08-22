# frozen_string_literal: true

# What an experimental setting was for one session, at the two moments worth
# knowing: the first time the session ran, and the last time it did.
#
# Intermediate toggles are deliberately not tracked — the point of the pair is
# not a full history, it is a cohort label plus enough information to know when
# the label is unsafe. A session whose two ends disagree ran under both settings
# and belongs in neither cohort; `cohort` names that case rather than rounding it
# into one side.
#
# WHY THE VALUE IS STORED AND NOT DERIVED
#
# The value could be re-derived at read time from the session's date and the date
# the setting shipped. That works exactly once — for the single step change a
# setting makes when it lands — and stops working the moment the setting is
# toggled back and forth, which is the whole point of having a toggle. Storing
# what was actually observed is what lets the cohorts interleave in time, and
# interleaved cohorts are the difference between an A/B test and a before/after
# chart. The date-derived path exists only for history that predates this table,
# and rows written that way are labelled `source = "backfilled"`.
class SessionExperimentalFlag < ApplicationRecord
  BACKFILLED = "backfilled"
  OBSERVED = "observed"

  # SQL that buckets a row into its cohort. Shared by the model and by
  # CostAnalytics so the page and a row can never disagree about which cohort a
  # session is in. `alias` is the table alias the expression is used under.
  def self.cohort_sql(alias_name = "session_experimental_flags")
    <<~SQL.squish
      CASE
        WHEN #{alias_name}.value_at_start IS NULL THEN 'unknown'
        WHEN #{alias_name}.value_at_end IS NOT NULL
             AND #{alias_name}.value_at_end <> #{alias_name}.value_at_start THEN 'mixed'
        WHEN #{alias_name}.value_at_start THEN 'on'
        ELSE 'off'
      END
    SQL
  end

  belongs_to :session

  validates :setting_key, presence: true
  validates :setting_key, uniqueness: { scope: :session_id }
  validates :source, inclusion: { in: [ OBSERVED, BACKFILLED ] }

  scope :for_setting, ->(key) { where(setting_key: key) }
  scope :observed, -> { where(source: OBSERVED) }
  scope :backfilled, -> { where(source: BACKFILLED) }

  # "on", "off", "mixed" (the setting was toggled while the session ran) or
  # "unknown" (nothing was ever observed).
  def cohort
    return "unknown" if value_at_start.nil?
    return "mixed" if !value_at_end.nil? && value_at_end != value_at_start
    value_at_start ? "on" : "off"
  end

  # Tag `session` with every experimental setting's current value.
  #
  # Called at both ends of a session's life — as it starts or resumes, and as it
  # pauses, fails or is archived. The first call fixes `value_at_start`; every
  # call moves `value_at_end`. That is what makes a mid-session toggle show up as
  # a disagreement between the two rather than vanishing.
  #
  # Idempotent, single round trip, and deliberately swallowing: this runs inside
  # session state transitions, and a bookkeeping write must never be the reason a
  # session fails to start.
  def self.record!(session, at: Time.current)
    return if session.nil? || session.id.nil?

    values = ExperimentalSettingsRegistry.current_values
    return if values.empty?

    rows = values.map do |key, value|
      {
        session_id: session.id, setting_key: key,
        value_at_start: value, value_at_end: value,
        source: OBSERVED,
        first_observed_at: at, last_observed_at: at,
        created_at: at, updated_at: at
      }
    end

    # `value_at_start` and `source` are deliberately absent from the update list:
    # the first observation owns them forever. A backfilled row keeps its
    # inferred start (the session really did begin before this table existed) and
    # keeps saying so.
    upsert_all(
      rows,
      unique_by: [ :session_id, :setting_key ],
      on_duplicate: Arel.sql(
        "value_at_end = EXCLUDED.value_at_end, " \
        "last_observed_at = EXCLUDED.last_observed_at, " \
        "updated_at = EXCLUDED.updated_at"
      )
    )
  rescue StandardError => e
    Rails.logger.warn("[SessionExperimentalFlag] could not tag session #{session&.id}: #{e.class}: #{e.message}")
    nil
  end
end
