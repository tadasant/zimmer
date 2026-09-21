require "administrate/base_dashboard"

class ExternalAppDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    name: Field::String,
    description: Field::Text,
    enabled: Field::Boolean,
    last_invoked_at: Field::DateTime,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  COLLECTION_ATTRIBUTES = %i[
    id
    name
    enabled
    last_invoked_at
    created_at
  ].freeze

  SHOW_PAGE_ATTRIBUTES = ATTRIBUTE_TYPES.keys.freeze

  # Read-only. Plugins are managed on /settings/plugins and `action_external_app`,
  # which keep the allowlist valid and write the audit line; a generic form would not.
  FORM_ATTRIBUTES = %i[].freeze

  COLLECTION_FILTERS = {}.freeze

  def display_resource(external_app)
    external_app.name
  end
end
