require "administrate/base_dashboard"

class AppSettingDashboard < Administrate::BaseDashboard
  # `app_settings` is a single-row table that holds every deployment-wide knob, and
  # it grows every time a subsystem needs one. Everything on it is either here or in
  # DELIBERATELY_OMITTED — test/dashboards/dashboard_schema_coverage_test.rb enforces
  # that, so a new knob is visible on the panel from the deploy that adds it.
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    default_runtime: Field::String,
    default_model: Field::String,
    # The spot gate. `spot_gating_enabled` is the master switch; the reserves are the
    # share of each quota window the gate keeps back from spot sessions.
    # SpotPoliciesController is the purpose-built surface for these.
    spot_gating_enabled: Field::Boolean,
    spot_max_concurrent_sessions: Field::Number,
    # Whether a priority session may take a slot off a running spot session when
    # the fleet is at that limit — SpotPreemption.
    spot_preemption_enabled: Field::Boolean,
    spot_reserve_five_hour_pct: Field::Number,
    spot_reserve_weekly_pct: Field::Number,
    # The quota pool's cached verdict, and when it last flipped.
    quota_pool_available: Field::Boolean,
    quota_pool_available_changed_at: Field::DateTime,
    # A JSONB record of the queue drain that recovery mode is running, rendered
    # verbatim. /health is where an operator normally reads this.
    queue_recovery_mode: Field::String.with_options(searchable: false),
    mcp_tool_search_enabled: Field::Boolean,
    session_scoped_credentials_enabled: Field::Boolean,
    # The removable-extension registry: a JSONB map of extension id => on/off,
    # read through AppSetting's extension accessors rather than as a column.
    extension_states: Field::String.with_options(searchable: false),
    # A JSONB map of session genesis => scheduling class, overriding the default
    # classification. Validated by the model, so a bad edit here is rejected.
    genesis_class_overrides: Field::String.with_options(searchable: false),
    # The fleet-idle detector's thresholds and its two clocks: when the fleet
    # crossed below its ceiling, and when top-up last fired.
    fleet_idle_threshold_minutes: Field::Number,
    fleet_idle_max_sessions: Field::Number,
    fleet_idle_min_fire_interval_minutes: Field::Number,
    fleet_idle_since: Field::DateTime,
    fleet_idle_event_fired_at: Field::DateTime,
    uncategorized_position: Field::Number,
    # The two categorization knobs. CategorizationController is the purpose-built
    # surface for these; the guidance is APPENDED to the fixed category task, never
    # a replacement for it.
    category_guidance: Field::Text,
    category_inference_model: Field::String,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  COLLECTION_ATTRIBUTES = %i[
    id
    default_runtime
    default_model
    spot_gating_enabled
    quota_pool_available
    updated_at
  ].freeze

  SHOW_PAGE_ATTRIBUTES = ATTRIBUTE_TYPES.keys.freeze

  # Read-only apart from the two defaults, and that is the deliberate part of this
  # change. Making every knob writable here would give each one a second editor
  # alongside the page that already owns it — the spot gate has /inference, the
  # extension registry has the settings page, `queue_recovery_mode` and the
  # `fleet_idle_*` and `quota_pool_*` state are written by pollers that would
  # overwrite a hand edit anyway. The panel's job here is to show what the row
  # actually holds, which is what it was failing to do.
  FORM_ATTRIBUTES = %i[
    default_runtime
    default_model
  ].freeze

  COLLECTION_FILTERS = {}.freeze
end
