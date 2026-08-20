require "administrate/base_dashboard"

class OutcomeAnalysisBatchDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    items: Field::HasMany.with_options(class_name: "OutcomeAnalysisBatchItem"),
    filters: Field::Text,
    concurrency: Field::Number,
    status: Field::String,
    total_count: Field::Number,
    finished_at: Field::DateTime,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  COLLECTION_ATTRIBUTES = %i[
    id
    status
    concurrency
    total_count
    created_at
  ].freeze

  SHOW_PAGE_ATTRIBUTES = ATTRIBUTE_TYPES.keys.freeze

  # `status` only: the Outcomes page owns starting and stopping a batch, and its
  # Stop button also cancels the queued items. This is the escape hatch for a
  # batch wedged in `running` that neither the pump nor Stop could resolve —
  # everything else about a batch is a record of what was asked for.
  FORM_ATTRIBUTES = %i[
    status
  ].freeze

  COLLECTION_FILTERS = {}.freeze
end
