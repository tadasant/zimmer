require "administrate/base_dashboard"

class McpServerOauthRequirementDashboard < Administrate::BaseDashboard
  # ATTRIBUTE_TYPES
  # a hash that describes the type of each of the model's fields.
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    server_name: Field::String,
    credential_key: Field::String,
    server_url: Field::String,
    determination: Field::String,
    # What the row still supports *today*, which is not always what it says: an
    # `advertised_not_required` past its TTL has already degraded to
    # `undetermined` in the code. Showing only the stored column would let this
    # page disagree with the behaviour it exists to explain.
    effective_determination: Field::String.with_options(searchable: false),
    detail: Field::String,
    determined_at: Field::DateTime,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  # COLLECTION_ATTRIBUTES
  # an array of attributes that will be displayed on the model's index page.
  # Both determinations, side by side: the stored one is the column (and the
  # sortable one), the effective one is what the code will actually act on
  # today. They differ exactly when a row has gone stale, which is the case
  # worth spotting from the index.
  COLLECTION_ATTRIBUTES = %i[
    id
    server_name
    determination
    effective_determination
    determined_at
  ].freeze

  # SHOW_PAGE_ATTRIBUTES
  # an array of attributes that will be displayed on the model's show page.
  SHOW_PAGE_ATTRIBUTES = %i[
    id
    server_name
    credential_key
    server_url
    determination
    effective_determination
    detail
    determined_at
    created_at
    updated_at
  ].freeze

  # FORM_ATTRIBUTES
  # Empty, and the route is read-only plus destroy to match. Every row is a
  # record of what a remote MCP server answered when Zimmer last asked it, so
  # hand-authoring one would forge an advertisement the server never made — and
  # a forged `advertised_not_required` is exactly the silent failure the model
  # is built to avoid. Deleting a row is the sanctioned correction: the next
  # probe re-records it, and until then the determination falls back to
  # "undetermined", which assumes OAuth might be required.
  FORM_ATTRIBUTES = [].freeze

  COLLECTION_FILTERS = {}.freeze

  def display_resource(requirement)
    "#{requirement.server_name} — #{requirement.effective_determination}"
  end
end
