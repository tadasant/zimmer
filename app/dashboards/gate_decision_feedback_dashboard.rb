require "administrate/base_dashboard"

class GateDecisionFeedbackDashboard < Administrate::BaseDashboard
  # ATTRIBUTE_TYPES
  # a hash that describes the type of each of the model's fields.
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    gate_decision: Field::BelongsTo,
    verdict: Field::String,
    note: Field::Text,
    received_at: Field::Date,
    author: Field::String,
    channel: Field::String,
    payload: Field::String.with_options(searchable: false),
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  # COLLECTION_ATTRIBUTES
  # an array of attributes that will be displayed on the model's index page.
  COLLECTION_ATTRIBUTES = %i[
    id
    gate_decision
    verdict
    author
    received_at
  ].freeze

  # SHOW_PAGE_ATTRIBUTES
  # an array of attributes that will be displayed on the model's show page.
  SHOW_PAGE_ATTRIBUTES = %i[
    id
    gate_decision
    verdict
    note
    received_at
    author
    channel
    payload
    created_at
    updated_at
  ].freeze

  # FORM_ATTRIBUTES
  #
  # Deliberately empty, and there is no create route either. This table records a
  # human overruling a gate, and its entire value is that a machine did not write
  # it: the author is resolved from the authenticated actor at the web-UI
  # boundary, never from a form field somebody typed. An admin form here would be
  # a way to author one under any name, which is the forgery the design refuses.
  # Rows are append-only, so there is nothing to edit and nothing to remove.
  FORM_ATTRIBUTES = %i[].freeze

  # COLLECTION_FILTERS
  # a hash that defines filters that can be used while searching via the search
  # field of the dashboard.
  COLLECTION_FILTERS = {
    typed_by_a_human: ->(resources) { resources.where(channel: GateDecisionFeedback::WEB_UI) },
    backfilled: ->(resources) { resources.where(channel: GateDecisionFeedback::IMPORTED) }
  }.freeze
end
