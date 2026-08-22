require "administrate/base_dashboard"

class SessionExperimentalFlagDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    session: Field::BelongsTo,
    setting_key: Field::String,
    value_at_start: Field::Boolean,
    value_at_end: Field::Boolean,
    source: Field::String,
    first_observed_at: Field::DateTime,
    last_observed_at: Field::DateTime,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  COLLECTION_ATTRIBUTES = %i[
    id
    session
    setting_key
    value_at_start
    value_at_end
    source
  ].freeze

  SHOW_PAGE_ATTRIBUTES = ATTRIBUTE_TYPES.keys.freeze

  # Read-only. These are observations — what a setting was when a session ran —
  # and the Costs page's cohort comparison is only worth anything if they stay
  # that way. Editing one by hand would move a session between cohorts with no
  # record that anything was changed, which is indistinguishable from the data
  # having said so all along.
  FORM_ATTRIBUTES = %i[].freeze

  COLLECTION_FILTERS = {}.freeze
end
