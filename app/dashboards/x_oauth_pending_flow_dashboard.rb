require "administrate/base_dashboard"

# X consents in progress (#852). Read-only plus destroy: a flow is only ever
# started by Supervisor::XOauthAuthorizationsController, and a hand-written one
# would have no consent behind it. Destroying one cancels that consent.
class XOauthPendingFlowDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    account_key: Field::String,
    access_token_env_var: Field::String,
    state: Field::String.with_options(searchable: false),
    redirect_uri: Field::String,
    expires_at: Field::DateTime,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  # DELIBERATELY_OMITTED
  # columns that exist on the table and are intentionally not rendered here.
  # test/dashboards/dashboard_schema_coverage_test.rb reads this.
  DELIBERATELY_OMITTED = [
    # The PKCE verifier is the secret that redeems an authorization code for this
    # flow. Nothing an operator does here needs to see it.
    :code_verifier
  ].freeze

  COLLECTION_ATTRIBUTES = %i[
    id
    account_key
    access_token_env_var
    expires_at
  ].freeze

  SHOW_PAGE_ATTRIBUTES = %i[
    id
    account_key
    access_token_env_var
    state
    redirect_uri
    expires_at
    created_at
    updated_at
  ].freeze

  FORM_ATTRIBUTES = [].freeze

  COLLECTION_FILTERS = {}.freeze

  def display_resource(flow)
    "#{flow.account_key} (#{flow.access_token_env_var})"
  end
end
