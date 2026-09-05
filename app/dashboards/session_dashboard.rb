require "administrate/base_dashboard"

class SessionDashboard < Administrate::BaseDashboard
  # ATTRIBUTE_TYPES
  # a hash that describes the type of each of the model's fields.
  #
  # Each different type represents an Administrate::Field object,
  # which determines how the attribute is displayed
  # on pages throughout the dashboard.
  #
  # Every column on `sessions` is either here or in DELIBERATELY_OMITTED below —
  # test/dashboards/dashboard_schema_coverage_test.rb enforces that, because
  # Administrate renders a panel that is missing a column without complaining.
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    slug: Field::String,
    title: Field::String,
    agent_runtime: Field::String,
    branch: Field::String,
    config: Field::String.with_options(searchable: false),
    # A select rather than a text box: the model accepts exactly one value, and the admin
    # form is the third surface (with the REST API and the MCP start_session tool) that
    # advertises what a caller may set. All three read Session::EXECUTION_PROVIDERS.
    execution_provider: Field::Select.with_options(collection: Session::EXECUTION_PROVIDERS),
    logs: Field::HasMany,
    subagent_transcripts: Field::HasMany,
    mcp_server_env: Field::String.with_options(searchable: false),
    mcp_server_headers: Field::String.with_options(searchable: false),
    mcp_servers: Field::String.with_options(searchable: false),
    catalog_skills: Field::String.with_options(searchable: false),
    catalog_plugins: Field::String.with_options(searchable: false),
    catalog_hooks: Field::String.with_options(searchable: false),
    prompt: Field::Text,
    goal: Field::Text,
    git_root: Field::String,
    subdirectory: Field::String,
    repository_name: Field::String,
    status: Field::Select.with_options(searchable: false, collection: ->(field) { field.resource.class.send(field.attribute.to_s.pluralize).keys }),
    visibility: Field::String,
    snoozed_until: Field::DateTime,
    archived_at: Field::DateTime,
    trash_after: Field::DateTime,
    # The scheduling axes. Both are plain strings/integers on the model rather than
    # enums, so they are rendered as such; the spot gate reads them, not this panel.
    scheduling_class: Field::String,
    precedence: Field::Number,
    genesis: Field::String,
    # `parent_session` and `category` carry the two foreign keys on the table.
    # Administrate cannot infer the class behind `parent_session`, hence class_name.
    parent_session: Field::BelongsTo.with_options(class_name: "Session"),
    category: Field::BelongsTo,
    # The bags the rest of the app hangs structured state off. `metadata` is
    # Zimmer's own (clone_path, agent_root_key, trigger_id); `custom_metadata` is
    # the caller's. Between them they answer most "why is this session like this"
    # questions, which is the reason someone opens this page at all.
    metadata: Field::String.with_options(searchable: false),
    custom_metadata: Field::String.with_options(searchable: false),
    session_notes: Field::Text,
    session_notes_updated_at: Field::DateTime,
    # The runtime's own id for the conversation (the Claude Code / Codex session
    # id), not a foreign key into this table — `parent_session` is that.
    session_id: Field::String,
    job_id: Field::String,
    running_job_id: Field::String,
    idempotency_key: Field::String,
    heartbeat_enabled: Field::Boolean,
    heartbeat_interval_seconds: Field::Number,
    heartbeat_last_beat_at: Field::DateTime,
    is_autonomous: Field::Boolean,
    push_notifications_enabled: Field::Boolean,
    favorited: Field::Boolean,
    sort_order: Field::Number,
    auto_compact_window: Field::Number,
    last_broadcast_to_index_at: Field::DateTime,
    last_timeline_entry_at: Field::DateTime,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  # DELIBERATELY_OMITTED
  # columns that exist on the table and are intentionally not rendered here.
  # The schema-coverage test reads this, so an omission is a reviewed decision
  # rather than a gap nobody noticed.
  DELIBERATELY_OMITTED = [
    # The whole conversation, as JSON. Routinely multiple megabytes on a long
    # session — rendering it would make the show page unusable and the index
    # page slow enough to time out. /sessions/:id streams it properly.
    :transcript
  ].freeze

  # COLLECTION_ATTRIBUTES
  # an array of attributes that will be displayed on the model's index page.
  #
  # By default, it's limited to four items to reduce clutter on index pages.
  # Feel free to add, remove, or rearrange items.
  COLLECTION_ATTRIBUTES = %i[
    id
    title
    status
    git_root
    created_at
  ].freeze

  # SHOW_PAGE_ATTRIBUTES
  # an array of attributes that will be displayed on the model's show page.
  #
  # Everything ATTRIBUTE_TYPES knows about: this is the page someone opens to
  # answer "why is this session in this state", and a field missing from it is
  # invisible rather than obviously absent.
  SHOW_PAGE_ATTRIBUTES = ATTRIBUTE_TYPES.keys.freeze

  # FORM_ATTRIBUTES
  # an array of attributes that will be displayed
  # on the model's form (`new` and `edit`) pages.
  #
  # Deliberately much shorter than the list above. Most of these columns are
  # written by the state machine, the scheduler or the runtime, and a generic
  # form that lets an operator hand-edit `archived_at`, `job_id` or
  # `heartbeat_last_beat_at` is a way to corrupt a session, not to operate one.
  # `session_notes` is left out for a sharper reason: every writer of it also
  # stamps `session_notes_updated_at`, which a generic form would not, so an
  # edit here would silently date the notes wrong. The purpose-built surfaces
  # (/sessions/:id, the REST API, the MCP tools) own all of these; this panel
  # reads them.
  FORM_ATTRIBUTES = %i[
    title
    agent_runtime
    branch
    config
    execution_provider
    logs
    mcp_server_env
    mcp_server_headers
    mcp_servers
    prompt
    goal
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
end
