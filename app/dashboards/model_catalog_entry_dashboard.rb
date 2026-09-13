require "administrate/base_dashboard"

class ModelCatalogEntryDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    runtime: Field::String,
    model_id: Field::String,
    label: Field::String,
    requires_oauth: Field::Boolean,
    cli_listed: Field::Boolean,
    cli_version: Field::String,
    cli_note: Field::Text,
    added_via: Field::String,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  COLLECTION_ATTRIBUTES = %i[
    id
    runtime
    model_id
    cli_listed
    cli_version
    added_via
    created_at
  ].freeze

  SHOW_PAGE_ATTRIBUTES = ATTRIBUTE_TYPES.keys.freeze

  # Read-only. Models are added and removed on /settings/models, the REST API and
  # `manage_models`, all through ModelCatalogEntry.add, which runs the CLI check.
  # A generic form here would write a row that skipped it.
  FORM_ATTRIBUTES = %i[].freeze

  COLLECTION_FILTERS = {}.freeze
end
