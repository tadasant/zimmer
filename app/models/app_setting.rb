# frozen_string_literal: true

# Global, user-tunable application defaults — a singleton row.
#
# Holds the global *base* default runtime + model: the value the session-creation
# fallback chain uses when nothing more specific is defined. The chain is:
#
#   form/API param  →  roots.json explicit value  →  AppSetting (this)  →  hardcoded default
#
# This setting NEVER overrides an explicit `default_runtime`/`default_model` in
# roots.json (those are applied with `config["..."] ||` before this is consulted)
# nor a per-session param. It only supplies a value when everything else is blank.
#
# Both columns are nullable. A blank value means "no global override" and the
# resolution falls through to the hardcoded default (Claude Code / opus, or the
# runtime's catalog default). The pair is validated so an unusable combination
# (e.g. Claude Code + a GPT model, which the Claude Code harness can't run) can
# never be persisted.
class AppSetting < ApplicationRecord
  # Where the dashboard's "Uncategorized" section sits in the category stack when no
  # explicit ordering has been persisted. 0 keeps it at the top, matching the
  # historical behavior before the section became reorderable.
  DEFAULT_UNCATEGORIZED_POSITION = 0

  # How much of a quota window is held back for priority sessions, as a
  # percentage of the window. The operator sets a percentage; QuotaCapacityModel
  # turns it into the dollar reserve the gate and the page reason in — see that
  # class for why the input and the displayed quantity are different units.
  #
  # 20 leaves four fifths of every window for spot work to fill, which is the
  # complement of the 80% fill target this replaced.
  DEFAULT_SPOT_RESERVE_PCT = 20

  # Whether newly spawned Claude Code sessions run with MCP tool search on
  # (ENABLE_TOOL_SEARCH=true), letting the agent search MCP tools on demand
  # instead of loading every attached server's tool schemas up front. ON is the
  # default: with several servers attached, the up-front schema load is a large,
  # unavoidable context cost at the start of every session.
  DEFAULT_MCP_TOOL_SEARCH_ENABLED = true

  # Whether Claude Code sessions run under their own CLAUDE_CONFIG_DIR with an
  # access token handed in via CLAUDE_CODE_OAUTH_TOKEN, making the DB the sole
  # owner of the subscription refresh chain (issue #618). OFF is the default and
  # the off path is the pre-existing shared-credentials-file behaviour, which is
  # what makes flipping this back a rollback rather than a migration.
  DEFAULT_SESSION_SCOPED_CREDENTIALS_ENABLED = false

  # How many sessions may run at once. The gate admits spot work in parallel up to
  # the concurrency the quota can carry, and this is the brake on that — 10 is the
  # number Tadas named. Every running session counts against it, priority included;
  # only spot ones are held by it.
  DEFAULT_SPOT_MAX_CONCURRENT_SESSIONS = 10

  # How few sessions the fleet has to be running before `no_sessions_in_progress`
  # counts it as idle enough to take more work. The count is sessions actually
  # `running` and nothing else, and the test is strictly BELOW this number — so 1
  # means "nothing running", which is the boolean the threshold replaced.
  #
  # 3 is the shipped default: a deployment with ten slots and two sessions in
  # them has capacity nobody is using, and requiring the last one to finish before
  # the backlog is topped up holds the fleet at a fifth of what it is paid for.
  # See FleetIdleMonitor.
  DEFAULT_FLEET_IDLE_MAX_SESSIONS = 3

  # How long the fleet has to stay under that ceiling before the event fires.
  # Five minutes is long enough that the gap between one session ending and the
  # next starting is not mistaken for an idle fleet.
  DEFAULT_FLEET_IDLE_THRESHOLD_MINUTES = 5

  # The floor between two fires, however many times the fleet dips under the
  # ceiling in between. Once the ceiling stops being the binding term this is
  # what caps top-up frequency — at 60 minutes, 24 fires a day. See
  # FleetIdleMonitor, "Why a cooldown as well as a latch".
  DEFAULT_FLEET_IDLE_MIN_FIRE_INTERVAL_MINUTES = 60

  # Null-object stand-in used only when the table can't be read (e.g. during a
  # migration run before the table exists, or in a DB-less boot path). It answers
  # the same read interface as a blank record so AgentRootsConfig never crashes on
  # a missing table — resolution simply falls through to the hardcoded defaults.
  NULL = Data.define(:default_runtime, :default_model) do
    def resolved_default_model_for(runtime)
      ModelCatalog.default_for(runtime)
    end

    def uncategorized_position
      DEFAULT_UNCATEGORIZED_POSITION
    end

    # No persisted enablement exists, so every Zimmer Extension resolves to its own
    # default (off, unless the extension opts in). Keeps ExtensionRegistry safe
    # in a DB-less boot path.
    def extension_states
      {}
    end

    def extension_enabled?(_id, default: false)
      default
    end

    # No persisted policy exists, so the spot gate is off and every genesis
    # resolves to its shipped default. A DB-less boot never throttles anything.
    def spot_gating_enabled
      false
    end
    alias_method :spot_gating_enabled?, :spot_gating_enabled

    def spot_reserve_five_hour_pct
      DEFAULT_SPOT_RESERVE_PCT
    end

    def spot_reserve_weekly_pct
      DEFAULT_SPOT_RESERVE_PCT
    end

    def spot_max_concurrent_sessions
      DEFAULT_SPOT_MAX_CONCURRENT_SESSIONS
    end

    # No persisted row exists, so the fleet top-up policy resolves to its shipped
    # numbers. A DB-less boot fires nothing anyway — FleetIdleMonitor bails on an
    # unreadable fleet — but the readers have to answer.
    def fleet_idle_max_sessions
      DEFAULT_FLEET_IDLE_MAX_SESSIONS
    end

    def fleet_idle_threshold_minutes
      DEFAULT_FLEET_IDLE_THRESHOLD_MINUTES
    end

    def fleet_idle_min_fire_interval_minutes
      DEFAULT_FLEET_IDLE_MIN_FIRE_INTERVAL_MINUTES
    end

    # No row means no observation, which is what NULL means on a real row too.
    # FleetTopUpStatus reads both unconditionally, so a DB-less boot needs them to
    # answer rather than raise.
    def fleet_idle_since
      nil
    end

    def fleet_idle_event_fired_at
      nil
    end

    def genesis_class_overrides
      {}
    end

    # No persisted row exists, so tool search resolves to its shipped default.
    def mcp_tool_search_enabled
      DEFAULT_MCP_TOOL_SEARCH_ENABLED
    end
    alias_method :mcp_tool_search_enabled?, :mcp_tool_search_enabled

    # No persisted row exists, so sessions keep the shared-credentials-file
    # behaviour. A DB-less boot never opts a session into the new scheme.
    def session_scoped_credentials_enabled
      DEFAULT_SESSION_SCOPED_CREDENTIALS_ENABLED
    end
    alias_method :session_scoped_credentials_enabled?, :session_scoped_credentials_enabled
  end.new(default_runtime: nil, default_model: nil)

  validates :default_runtime,
    inclusion: { in: -> { RuntimeRegistry.registered_runtimes }, message: "%{value} is not a registered runtime" },
    allow_blank: true
  validate :default_model_valid_for_runtime
  validate :only_one_row, on: :create
  # 0 and 100 are both meaningful and both allowed: 0% reserves nothing and lets
  # spot work fill the entire window, 100% reserves all of it and holds every
  # spot session. Neither is a mistake to validate away.
  validates :spot_reserve_five_hour_pct, :spot_reserve_weekly_pct,
    numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }
  # At least one: a cap of zero would hold every spot session forever, which is
  # what turning the gate off (or setting a target of 0) is for.
  validates :spot_max_concurrent_sessions,
    numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 100 }
  # At least one, for the same reason: the test is `running_sessions < ceiling`,
  # so a ceiling of 0 can never be satisfied and the event would never fire again.
  # 1 means "nothing running".
  validates :fleet_idle_max_sessions,
    numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 100 }
  # A minute is the cron cadence FleetIdleCheckerJob samples at, so it is the
  # finest either clock can mean anything at. A day is a generous ceiling on
  # "how long must it stay quiet"; a week on "how rarely may it fire".
  validates :fleet_idle_threshold_minutes,
    numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 1440 }
  validates :fleet_idle_min_fire_interval_minutes,
    numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 10_080 }
  validate :genesis_class_overrides_well_formed

  class << self
    # The singleton row for reads. Returns a blank, unsaved record when no row
    # exists yet, and the NULL object if the table can't be queried — so callers
    # in the hot path (AgentRootsConfig) never raise.
    #
    # This is the ONLY place a settings read degrades. Everything else — the
    # class-method wrappers below, ExperimentalSettingsRegistry, QueueRecoveryMode
    # — reads through here and lets NULL answer, so one failed `SELECT` produces
    # exactly one log line naming exactly one caller. A second rescue layered on
    # top would report the same failure twice, which is a smaller copy of the
    # thing issue #924 was.
    #
    # Two properties of that degrade are load-bearing, and both are #924:
    #
    #   * It logs, at the site that failed. `context` names the caller, because
    #     "the settings row could not be read" is only useful alongside who was
    #     reading it — and a silent rescue here is why production held four
    #     `InFailedSqlTransaction` errors and no record of their cause.
    #
    #   * It does not degrade on a poisoned connection. Once the failed statement
    #     has aborted the transaction, Postgres rejects everything later in it and
    #     the transaction cannot commit, so there is nothing to degrade to:
    #     returning a default only lets the caller run on toward a misleading
    #     error. Re-raise, and the caller's own rescue reports the real cause.
    #     See DatabaseTransactionState.
    def current(context: "AppSetting.current")
      order(:id).first || new
    rescue ActiveRecord::StatementInvalid, ActiveRecord::NoDatabaseError => e
      Rails.logger.warn(
        "[AppSetting] #{context} could not read the settings row: #{e.class}: #{e.message}"
      )
      # Sentry held all four consequences of #924 and none of the cause. Report
      # the cause where the consequences already land.
      Rails.error.report(e, handled: true, severity: :warning, context: { read: context })
      raise if DatabaseTransactionState.aborted_by?(e)

      NULL
    end

    # The singleton row for writes. Like #current but without the NULL fallback,
    # so the settings form gets a real, persistable record (inserting the first
    # row when none exists).
    def editable
      order(:id).first || new
    end

    # Whether the Zimmer Extension with the given id is enabled, per the persisted
    # settings row. Falls back to `default` whenever the row or column can't be
    # read, so Zimmer::ExtensionRegistry stays safe in the hot path and DB-less boots.
    # This is the single global enablement lookup for every extension — adding an
    # extension needs no new column, only a key in the extension_states JSONB map.
    def extension_enabled?(id, default: false)
      current(context: "AppSetting.extension_enabled?(#{id})").extension_enabled?(id, default: default)
    end

    # Whether spawned Claude Code sessions get MCP tool search. The single global
    # lookup ClaudeSpawnEnv consults on the session-spawn hot path, so it falls
    # back to the shipped default whenever the row can't be read rather than
    # raising mid-spawn.
    def mcp_tool_search_enabled?
      current(context: "AppSetting.mcp_tool_search_enabled?").mcp_tool_search_enabled?
    end

    # Whether Claude Code sessions get a per-session CLAUDE_CONFIG_DIR and a
    # CLAUDE_CODE_OAUTH_TOKEN instead of the shared credentials file. Read on the
    # spawn path, the auth sweep and the /inference render, so it falls back to the
    # shipped default whenever the row can't be read rather than raising.
    def session_scoped_credentials_enabled?
      current(context: "AppSetting.session_scoped_credentials_enabled?").session_scoped_credentials_enabled?
    end
  end

  # Whether the extension with `id` is enabled on this row, defaulting to
  # `default` when the row has no explicit state stored for it. Also returns
  # `default` when the extension_states column isn't present on this record —
  # the window where new code boots against a schema that predates the column's
  # migration — so the enablement lookup on the session-spawn hot path degrades
  # to native behavior instead of raising.
  def extension_enabled?(id, default: false)
    return default unless has_attribute?(:extension_states)

    stored = (extension_states || {})[id.to_s]
    return default if stored.nil?

    ActiveModel::Type::Boolean.new.cast(stored)
  end

  # Set the enabled/disabled state for the extension with `id`, without touching
  # any other extension's stored state.
  def set_extension_enabled(id, value)
    self.extension_states = (extension_states || {}).merge(id.to_s => !!value)
  end

  # Whether MCP tool search is on for this row. Returns the shipped default when
  # the column isn't present on the record — the window where new code boots
  # against a schema that predates the migration — so the spawn-env lookup
  # degrades to the default instead of raising.
  def mcp_tool_search_enabled?
    return DEFAULT_MCP_TOOL_SEARCH_ENABLED unless has_attribute?(:mcp_tool_search_enabled)

    !!self[:mcp_tool_search_enabled]
  end

  # Whether session-scoped credentials are on for this row. Returns the shipped
  # default when the column isn't present — the window where new code boots
  # against a schema that predates the migration — so the spawn path degrades to
  # the shared-file behaviour instead of raising.
  def session_scoped_credentials_enabled?
    return DEFAULT_SESSION_SCOPED_CREDENTIALS_ENABLED unless has_attribute?(:session_scoped_credentials_enabled)

    !!self[:session_scoped_credentials_enabled]
  end

  # The configured model when it is valid for `runtime`, otherwise the runtime's
  # own catalog default. Keeps a global model pinned to one runtime from leaking
  # into an incompatible one (e.g. global gpt-5.5 must not be handed to a root
  # that explicitly runs under Claude Code).
  def resolved_default_model_for(runtime)
    m = default_model
    return m if m.present? && ModelCatalog.valid_model?(runtime, m)

    ModelCatalog.default_for(runtime)
  end

  # Set one genesis kind's spot/priority class, leaving every other kind's stored
  # state alone — the same merge-not-replace discipline #set_extension_enabled
  # uses, so promoting one genesis can never clobber another.
  #
  # Only the kinds nothing triggers can be set here. The trigger-backed kinds
  # take their class from the Trigger row, and writing one of them into this
  # column would be a setting that silently does nothing — SessionGenesis
  # ignores it on read.
  #
  # Storing a value equal to the shipped default removes the key instead. That
  # keeps the column a record of deliberate divergence, so a later change to a
  # default is not silently pinned by a no-op override written months earlier.
  def set_genesis_class(genesis_key, klass)
    key = genesis_key.to_s
    klass = klass.to_s
    raise ArgumentError, "unknown genesis #{key}" unless SessionGenesis.valid?(key)
    raise ArgumentError, "#{key} takes its class from its trigger" unless SessionGenesis.settable?(key)
    raise ArgumentError, "unknown class #{klass}" unless SessionGenesis::CLASSES.include?(klass)

    stored = (genesis_class_overrides || {}).except(key)
    stored[key] = klass unless klass == SessionGenesis.default_class(key)
    self.genesis_class_overrides = stored
  end

  # Drop every override, returning all genesis kinds to their shipped defaults.
  def reset_genesis_classes
    self.genesis_class_overrides = {}
  end

  private

  def genesis_class_overrides_well_formed
    overrides = genesis_class_overrides
    return if overrides.blank?

    unless overrides.is_a?(Hash)
      errors.add(:genesis_class_overrides, "must be an object keyed by genesis")
      return
    end

    overrides.each do |key, klass|
      errors.add(:genesis_class_overrides, "#{key} is not a known genesis") unless SessionGenesis.valid?(key)
      errors.add(:genesis_class_overrides, "#{klass} is not a valid class") unless SessionGenesis::CLASSES.include?(klass.to_s)
    end
  end

  def default_model_valid_for_runtime
    return if default_model.blank?

    runtime = default_runtime.presence || RuntimeRegistry::DEFAULT_RUNTIME
    return if ModelCatalog.valid_model?(runtime, default_model)

    errors.add(:default_model, "#{default_model} is not available for #{RuntimeRegistry.label_for(runtime)}")
  end

  def only_one_row
    return unless self.class.where.not(id: id).exists?

    errors.add(:base, "Only one AppSetting row may exist")
  end
end
