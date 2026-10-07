require "administrate/base_dashboard"

class WebIdentityDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    email: Field::String,
    name: Field::String,
    hosted_domain: Field::String,
    google_sub: Field::String,
    totp_enrolled_at: Field::DateTime,
    recovery_codes_remaining: Field::Number,
    second_factor_failed_attempts: Field::Number,
    second_factor_locked_until: Field::DateTime,
    session_generation: Field::Number,
    last_signed_in_at: Field::DateTime,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  # DELIBERATELY_OMITTED
  # columns that exist on the table and are intentionally not rendered here.
  # test/dashboards/dashboard_schema_coverage_test.rb reads this.
  DELIBERATELY_OMITTED = [
    # The authenticator secrets. Whoever reads one can mint codes forever; the
    # setup page shows a pending one to its owner, once, and nothing else does.
    :totp_secret,
    :totp_pending_secret,
    # Replay bookkeeping: the last time step accepted. Meaningless to a reader.
    :totp_last_used_step,
    # Rendered as `recovery_codes_remaining`. The digests are of 50-bit codes,
    # so they are not brute-forceable, but a count is all anyone needs.
    :recovery_code_digests
  ].freeze

  COLLECTION_ATTRIBUTES = %i[
    id
    email
    hosted_domain
    totp_enrolled_at
    last_signed_in_at
  ].freeze

  SHOW_PAGE_ATTRIBUTES = ATTRIBUTE_TYPES.keys.freeze

  # Read-only. Rows are written by Google sign-in; destroy is the only change.
  FORM_ATTRIBUTES = %i[].freeze

  COLLECTION_FILTERS = {}.freeze

  def display_resource(web_identity)
    web_identity.email
  end
end
