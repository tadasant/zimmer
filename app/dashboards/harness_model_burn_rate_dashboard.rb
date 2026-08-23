require "administrate/base_dashboard"

class HarnessModelBurnRateDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    harness: Field::String,
    model: Field::String,
    usd_per_minute: Field::Number.with_options(decimals: 4),
    sample_cost_usd: Field::Number.with_options(decimals: 2),
    sample_minutes: Field::Number.with_options(decimals: 1),
    sample_session_count: Field::Number,
    sample_newest_at: Field::DateTime,
    sample_oldest_at: Field::DateTime,
    computed_at: Field::DateTime,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  COLLECTION_ATTRIBUTES = %i[
    id
    harness
    model
    usd_per_minute
    sample_session_count
    computed_at
  ].freeze

  SHOW_PAGE_ATTRIBUTES = %i[
    id
    harness
    model
    usd_per_minute
    sample_cost_usd
    sample_minutes
    sample_session_count
    sample_newest_at
    sample_oldest_at
    computed_at
    created_at
    updated_at
  ].freeze

  # Every column is derived by BurnRateRecomputeJob from the token ledger, so
  # there is nothing here a human should hand-edit: the next cron run would
  # overwrite it, and a rate that disagreed with the ledger would be a lie the
  # scheduler acts on.
  FORM_ATTRIBUTES = %i[].freeze

  COLLECTION_FILTERS = {}.freeze
end
