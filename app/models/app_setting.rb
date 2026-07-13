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
  end.new(default_runtime: nil, default_model: nil)

  validates :default_runtime,
    inclusion: { in: -> { RuntimeRegistry.registered_runtimes }, message: "%{value} is not a registered runtime" },
    allow_blank: true
  validate :default_model_valid_for_runtime
  validate :only_one_row, on: :create

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

  private

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
