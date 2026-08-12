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

  # The forecast ceiling a spot session must stay under to start, as a percentage
  # of the window. 80 is the value Tadas named; both windows default to it.
  DEFAULT_SPOT_GATE_THRESHOLD_PCT = 80

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

    def spot_gate_five_hour_threshold_pct
      DEFAULT_SPOT_GATE_THRESHOLD_PCT
    end

    def spot_gate_weekly_threshold_pct
      DEFAULT_SPOT_GATE_THRESHOLD_PCT
    end

    def genesis_class_overrides
      {}
    end
  end.new(default_runtime: nil, default_model: nil)

  validates :default_runtime,
    inclusion: { in: -> { RuntimeRegistry.registered_runtimes }, message: "%{value} is not a registered runtime" },
    allow_blank: true
  validate :default_model_valid_for_runtime
  validate :only_one_row, on: :create
  validates :spot_gate_five_hour_threshold_pct, :spot_gate_weekly_threshold_pct,
    numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }
  before_validation :prune_trigger_backed_class_overrides
  validate :genesis_class_overrides_well_formed

  class << self
    # The singleton row for reads. Returns a blank, unsaved record when no row
    # exists yet, and the NULL object if the table can't be queried — so callers
    # in the hot path (AgentRootsConfig) never raise.
    def current
      order(:id).first || new
    rescue ActiveRecord::StatementInvalid, ActiveRecord::NoDatabaseError
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
      current.extension_enabled?(id, default: default)
    rescue ActiveRecord::StatementInvalid, ActiveRecord::NoDatabaseError
      default
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

  # A key for a trigger-backed kind is dead weight: SessionGenesis ignores it on
  # read, so it can only mislead whoever opens the column next. Pruned rather
  # than rejected — a row written before the selector moved to Trigger must still
  # be saveable, and this converges it on the next write.
  def prune_trigger_backed_class_overrides
    return unless genesis_class_overrides.is_a?(Hash)

    pruned = genesis_class_overrides.select { |key, _| SessionGenesis.settable?(key) }
    self.genesis_class_overrides = pruned if pruned.size != genesis_class_overrides.size
  end

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
