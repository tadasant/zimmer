require "administrate/base_dashboard"

class SessionUncleLinkDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    session: Field::BelongsTo,
    uncle_session: Field::BelongsTo.with_options(class_name: "Session"),
    source: Field::String,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  COLLECTION_ATTRIBUTES = %i[
    id
    session
    uncle_session
    source
    created_at
  ].freeze

  SHOW_PAGE_ATTRIBUTES = %i[
    id
    session
    uncle_session
    source
    created_at
    updated_at
  ].freeze

  # No form attributes. Edges are written by Sessions::RecordUncleEdge, which is
  # what enforces the acyclicity invariant — hand-authoring one here would go
  # around it. Removing one recorded in error has product surfaces of its own
  # (the hierarchy panel's ×, `action_session` → `remove_uncle`, and
  # DELETE /api/v1/sessions/:id/uncle_links/:uncle_id, all through
  # Sessions::RemoveUncleEdge); the destroy here is the operator's escape hatch
  # for an edge those cannot name, and it records nothing on either timeline.
  FORM_ATTRIBUTES = [].freeze

  COLLECTION_FILTERS = {}.freeze
end
