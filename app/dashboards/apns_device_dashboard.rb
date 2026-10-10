require "administrate/base_dashboard"

class ApnsDeviceDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    token_hint: Field::String,
    environment: Field::String,
    device_name: Field::String,
    app_version: Field::String,
    oauth_server_grant_id: Field::Number,
    last_registered_at: Field::DateTime,
    last_delivered_at: Field::DateTime,
    disabled_at: Field::DateTime,
    disabled_reason: Field::String,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  # DELIBERATELY_OMITTED
  # columns that exist on the table and are intentionally not rendered here.
  # test/dashboards/dashboard_schema_coverage_test.rb reads this.
  DELIBERATELY_OMITTED = [
    # Rendered as `token_hint`: a delivery address, not a secret, but nobody reading
    # this page needs all of it.
    :token
  ].freeze

  COLLECTION_ATTRIBUTES = %i[
    id
    device_name
    environment
    last_registered_at
    last_delivered_at
    disabled_at
  ].freeze

  SHOW_PAGE_ATTRIBUTES = ATTRIBUTE_TYPES.keys.freeze

  # Read-only: phones register and unregister themselves from the app.
  FORM_ATTRIBUTES = %i[].freeze

  COLLECTION_FILTERS = {}.freeze

  def display_resource(device)
    device.device_name.presence || device.token_hint
  end
end
