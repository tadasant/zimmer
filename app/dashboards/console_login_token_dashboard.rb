require "administrate/base_dashboard"

class ConsoleLoginTokenDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    principal: Field::String,
    role: Field::String,
    status: Field::String,
    expires_at: Field::DateTime,
    session_ttl_seconds: Field::Number,
    consumed_at: Field::DateTime,
    revoked_at: Field::DateTime,
    minted_from_ip: Field::String,
    consumed_from_ip: Field::String,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  # DELIBERATELY_OMITTED
  # columns that exist on the table and are intentionally not rendered here.
  # test/dashboards/dashboard_schema_coverage_test.rb reads this, so an omission
  # is a reviewed decision rather than a gap nobody noticed.
  DELIBERATELY_OMITTED = [
    # The SHA-256 of the token's 256-bit random secret. Not reversible, and not
    # useful to anyone reading the panel; the row's id is what a log line names.
    :secret_digest
  ].freeze

  COLLECTION_ATTRIBUTES = %i[
    id
    principal
    status
    expires_at
    consumed_at
    revoked_at
    created_at
  ].freeze

  SHOW_PAGE_ATTRIBUTES = ATTRIBUTE_TYPES.keys.freeze

  # Read-only. A row is minted on POST /console_login_tokens, which is the one place
  # its token is ever shown, and its status moves by conditional UPDATE from the
  # exchange and the revoke. A generic form here could only write a row with no
  # secret behind it, or un-consume one without the log line that says so.
  FORM_ATTRIBUTES = %i[].freeze

  COLLECTION_FILTERS = {}.freeze

  def display_resource(token)
    "Console login token #{token.id} (#{token.principal})"
  end
end
