require "administrate/base_dashboard"

class SubagentTranscriptDashboard < Administrate::BaseDashboard
  # ATTRIBUTE_TYPES
  # a hash that describes the type of each of the model's fields.
  #
  # Each different type represents an Administrate::Field object,
  # which determines how the attribute is displayed
  # on pages throughout the dashboard.
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    agent_id: Field::String,
    description: Field::String,
    duration_ms: Field::Number,
    filename: Field::String,
    message_count: Field::Number,
    session: Field::BelongsTo,
    status: Field::String,
    subagent_type: Field::String,
    tool_use_count: Field::Number,
    tool_use_id: Field::String,
    total_tokens: Field::Number,
    transcript: Field::Text,
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
    session
    status
    subagent_type
  ].freeze

  # SHOW_PAGE_ATTRIBUTES
  # an array of attributes that will be displayed on the model's show page.
  SHOW_PAGE_ATTRIBUTES = %i[
    id
    session
    agent_id
    tool_use_id
    subagent_type
    description
    status
    message_count
    tool_use_count
    duration_ms
    total_tokens
    filename
    transcript
    created_at
    updated_at
  ].freeze

  # FORM_ATTRIBUTES
  # an array of attributes that will be displayed
  # on the model's form (`new` and `edit`) pages.
  FORM_ATTRIBUTES = %i[
    session
    agent_id
    tool_use_id
    subagent_type
    description
    status
    message_count
    tool_use_count
    duration_ms
    total_tokens
    filename
    transcript
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
end
