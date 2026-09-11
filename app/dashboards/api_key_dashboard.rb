require "administrate/base_dashboard"

class ApiKeyDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    name: Field::String,
    source: Field::String,
    effective_grant: Field::String,
    last_used_at: Field::DateTime,
    revoked_at: Field::DateTime,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  # DELIBERATELY_OMITTED
  # columns that exist on the table and are intentionally not rendered here.
  # test/dashboards/dashboard_schema_coverage_test.rb reads this, so an omission
  # is a reviewed decision rather than a gap nobody noticed.
  DELIBERATELY_OMITTED = [
    # Rendered as `effective_grant` instead, which is the same value on every
    # database that has the column and `api` on one that does not. Administrate
    # renders any public method, and reading the raw attribute would 500 this
    # page on a database whose migration has not run — the operator's own
    # diagnostic surface, during exactly the incident it would be opened for.
    :grant,
    # The SHA-256 of the key. Harmless for a minted key, but an API_KEYS entry is
    # only as strong as whoever chose it, and a short one can be brute-forced from
    # its digest. The API keys page shows an 8-character fingerprint instead.
    :token_digest
  ].freeze

  COLLECTION_ATTRIBUTES = %i[
    id
    name
    source
    effective_grant
    last_used_at
    revoked_at
  ].freeze

  SHOW_PAGE_ATTRIBUTES = ATTRIBUTE_TYPES.keys.freeze

  # Read-only. Keys are created, revoked and restored on /settings/api_keys, which
  # is the one place a key is ever shown. A generic form here could only write a
  # row with no key behind it, or un-revoke one without the log line that says so.
  FORM_ATTRIBUTES = %i[].freeze

  COLLECTION_FILTERS = {}.freeze

  def display_resource(api_key)
    api_key.name
  end
end
