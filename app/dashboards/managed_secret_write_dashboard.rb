require "administrate/base_dashboard"

# The audit trail of Zimmer's own writes to the Parameter Store.
#
# Read-only by construction: FORM_ATTRIBUTES is empty, so Administrate renders no
# new/edit form. Rows are append-only facts about what happened, and an editable
# audit log is not one.
#
# `fingerprint` is a truncated SHA-256 and is the closest this table ever comes to
# the value — there is deliberately no column that could hold the secret itself.
class ManagedSecretWriteDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    variable: Field::String,
    action: Field::String,
    outcome: Field::String,
    fingerprint: Field::String,
    project_id: Field::String,
    location: Field::String,
    detail: Field::Text,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  COLLECTION_ATTRIBUTES = %i[
    id
    variable
    action
    outcome
    fingerprint
    created_at
  ].freeze

  SHOW_PAGE_ATTRIBUTES = %i[
    id
    variable
    action
    outcome
    fingerprint
    project_id
    location
    detail
    created_at
    updated_at
  ].freeze

  FORM_ATTRIBUTES = %i[].freeze

  COLLECTION_FILTERS = {}.freeze
end
