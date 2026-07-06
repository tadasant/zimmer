require "administrate/base_dashboard"

class SessionDashboard < Administrate::BaseDashboard
  # ATTRIBUTE_TYPES
  # a hash that describes the type of each of the model's fields.
  #
  # Each different type represents an Administrate::Field object,
  # which determines how the attribute is displayed
  # on pages throughout the dashboard.
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    agent_runtime: Field::String,
    branch: Field::String,
    config: Field::String.with_options(searchable: false),
    execution_provider: Field::String,
    logs: Field::HasMany,
    subagent_transcripts: Field::HasMany,
    mcp_server_env: Field::String.with_options(searchable: false),
    mcp_server_headers: Field::String.with_options(searchable: false),
    mcp_servers: Field::String.with_options(searchable: false),
    prompt: Field::Text,
    git_root: Field::String,
    status: Field::Select.with_options(searchable: false, collection: ->(field) { field.resource.class.send(field.attribute.to_s.pluralize).keys }),
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  # COLLECTION_ATTRIBUTES
  # an array of attributes that will be displayed on the model's index page.
  #
  # By default, it's limited to four items to reduce clutter on index pages.
  # Feel free to add, remove, or rearrange items.
  COLLECTION_ATTRIBUTES = %i[
    id
    status
    prompt
    git_root
  ].freeze

  # SHOW_PAGE_ATTRIBUTES
  # an array of attributes that will be displayed on the model's show page.
  SHOW_PAGE_ATTRIBUTES = %i[
    id
    agent_runtime
    branch
    config
    execution_provider
    logs
    subagent_transcripts
    mcp_server_env
    mcp_server_headers
    mcp_servers
    prompt
    git_root
    status
    created_at
    updated_at
  ].freeze

  # FORM_ATTRIBUTES
  # an array of attributes that will be displayed
  # on the model's form (`new` and `edit`) pages.
  FORM_ATTRIBUTES = %i[
    agent_runtime
    branch
    config
    execution_provider
    logs
    mcp_server_env
    mcp_server_headers
    mcp_servers
    prompt
    git_root
    status
  ].freeze

  # COLLECTION_FILTERS
  # a hash that defines filters that can be used while searching via the search
  # field of the dashboard.
  #
  # For example to add an option to search for open resources by typing "open:"
  # in the search field:
  #
  #   COLLECTION_FILTERS = {
  #     open: ->(resources) { resources.where(open: true) }
  #   }.freeze
  COLLECTION_FILTERS = {}.freeze

  # Overwrite this method to customize how sessions are displayed
  # across all pages of the admin dashboard.
  #
  # def display_resource(session)
  #   "Session ##{session.id}"
  # end
end
