require "administrate/base_dashboard"

class QuotaCapacityEstimateDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    window_key: Field::String,
    capacity_usd: Field::Number.with_options(decimals: 2),
    observed_capacity_usd: Field::Number.with_options(decimals: 2),
    sample_cost_usd: Field::Number.with_options(decimals: 2),
    sample_utilization: Field::Number.with_options(decimals: 4),
    observation_count: Field::Number,
    computed_at: Field::DateTime,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  COLLECTION_ATTRIBUTES = %i[
    id
    window_key
    capacity_usd
    sample_utilization
    observation_count
    computed_at
  ].freeze

  SHOW_PAGE_ATTRIBUTES = %i[
    id
    window_key
    capacity_usd
    observed_capacity_usd
    sample_cost_usd
    sample_utilization
    observation_count
    computed_at
    created_at
    updated_at
  ].freeze

  # Read-only for the same reason the burn rates are: the figure is an estimate
  # QuotaCapacityCalibrationJob re-derives every fifteen minutes, and a
  # hand-typed capacity would be overwritten on the next run while the spot gate
  # spent against it in the meantime.
  FORM_ATTRIBUTES = %i[].freeze

  COLLECTION_FILTERS = {}.freeze
end
