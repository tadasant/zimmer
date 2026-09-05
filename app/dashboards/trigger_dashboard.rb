require "administrate/base_dashboard"

class TriggerDashboard < Administrate::BaseDashboard
  # Every column on `triggers` is either here or in DELIBERATELY_OMITTED —
  # test/dashboards/dashboard_schema_coverage_test.rb enforces it.
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    name: Field::String,
    status: Field::String,
    agent_root_name: Field::String,
    mcp_servers: Field::String.with_options(searchable: false),
    catalog_skills: Field::String.with_options(searchable: false),
    catalog_plugins: Field::String.with_options(searchable: false),
    catalog_hooks: Field::String.with_options(searchable: false),
    goal: Field::Text,
    prompt_template: Field::Text,
    # How the sessions this trigger spawns are scheduled. `scheduling_class` is
    # stamped onto each new session; blank means Trigger#default_scheduling_class
    # decides. Both are read by the spot gate, not by this panel.
    scheduling_class: Field::String,
    precedence: Field::Number,
    last_triggered_at: Field::DateTime,
    failed_at: Field::DateTime,
    last_error: Field::Text,
    sessions_created_count: Field::Number,
    reuse_session: Field::Boolean,
    resuscitate_archived: Field::Boolean,
    enqueue_messages: Field::Boolean,
    skip_if_pending_session: Field::Boolean,
    coalesce_window_seconds: Field::Number,
    max_sessions_per_minute: Field::Number,
    # The burst limiter's live state. Together these say whether the trigger is
    # currently throttled and what it counted in the open window — the fields you
    # want when a trigger has stopped firing and nobody knows why.
    burst_window_started_at: Field::DateTime,
    burst_window_count: Field::Number,
    burst_window_session_ids: Field::String.with_options(searchable: false),
    burst_active_until: Field::DateTime,
    wake_held_at: Field::DateTime,
    missed_fire_count: Field::Number,
    first_missed_fire_at: Field::DateTime,
    last_session_id: Field::Number,
    trigger_conditions: Field::HasMany,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  COLLECTION_ATTRIBUTES = %i[
    id
    name
    status
    sessions_created_count
    last_triggered_at
  ].freeze

  SHOW_PAGE_ATTRIBUTES = ATTRIBUTE_TYPES.keys.freeze

  # Conservative on purpose. The burst counters, `missed_fire_count` and
  # `last_triggered_at` are the limiter's and the scheduler's own bookkeeping:
  # hand-editing them through a generic form desynchronises the trigger from
  # what actually fired. They are readable above; they are not writable here.
  FORM_ATTRIBUTES = %i[
    name
    status
    agent_root_name
    mcp_servers
    goal
    prompt_template
  ].freeze

  COLLECTION_FILTERS = {}.freeze
end
