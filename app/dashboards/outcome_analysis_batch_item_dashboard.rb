require "administrate/base_dashboard"

class OutcomeAnalysisBatchItemDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    batch: Field::BelongsTo.with_options(class_name: "OutcomeAnalysisBatch"),
    session: Field::BelongsTo,
    analysis_session: Field::BelongsTo.with_options(class_name: "Session"),
    state: Field::String,
    position: Field::Number,
    error: Field::Text,
    started_at: Field::DateTime,
    finished_at: Field::DateTime,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  COLLECTION_ATTRIBUTES = %i[
    id
    batch
    session
    state
    position
  ].freeze

  SHOW_PAGE_ATTRIBUTES = ATTRIBUTE_TYPES.keys.freeze

  # `state` only, for the same reason the batch exposes `status`: an item stuck in
  # `running` behind an analysis session that will never finish can be moved on by
  # hand. The rest of the row records what the pump actually did.
  FORM_ATTRIBUTES = %i[
    state
  ].freeze

  COLLECTION_FILTERS = {}.freeze
end
