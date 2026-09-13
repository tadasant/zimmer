# frozen_string_literal: true

# A model an operator added to a runtime's catalog without a deploy (#85).
#
# ModelCatalog appends these rows to its built-in MODELS list, so everything that
# reads the catalog (the new-session form, the detail-page model editor, the
# Settings defaults, the REST API, `start_session`) offers an added model the same
# way it offers a built-in one. Rows are only ever added and removed. Neither the
# runtime's fallback default nor the quota probe's Messages API id can come from
# here: both are read at boot, and both stay in the literal.
#
# Add one through .add, never `create`. .add is the one write path the Settings
# page, `POST /api/v1/model_catalog_entries` and the `manage_models` MCP tool
# share. It validates what can be validated offline, then asks the installed CLI
# whether it knows the id (ModelCatalogCliCheck) and stores the answer on the row,
# where every surface that lists added models shows it.
class ModelCatalogEntry < ApplicationRecord
  ADDED_VIA = %w[web_ui api mcp].freeze

  # What a CLI's --model / -m takes: no whitespace, and nothing that starts like a
  # flag. Covers Pi's `provider/vendor/id:thinking`, Claude Code's `opus[1m]` and
  # the dotted Codex slugs.
  MODEL_ID_FORMAT = %r{\A[A-Za-z0-9][A-Za-z0-9._:~/\[\]@+-]*\z}
  # The session model editors (web, REST, MCP) cut a submitted model to 100
  # characters, so a longer id could be added but never picked.
  MAX_MODEL_ID_LENGTH = 100
  MAX_LABEL_LENGTH = 200

  # The same shape ModelCatalogTest refuses in the built-in list: a dated snapshot
  # in Anthropic's `-YYYYMMDD` form or Vertex's `@YYYYMMDD`.
  DATED_SNAPSHOT = /[-@]\d{8}\z/

  validates :runtime, inclusion: { in: ->(_) { ModelCatalog.runtimes }, message: "%{value} has no model catalog" }
  validates :model_id, presence: true, length: { maximum: MAX_MODEL_ID_LENGTH }
  validates :model_id, format: { with: MODEL_ID_FORMAT, message: "may contain only letters, digits and . _ : ~ / [ ] @ + -, and must start with a letter or digit" }, allow_blank: true
  validates :model_id, uniqueness: { scope: :runtime, message: "is already added for this runtime" }
  validates :label, length: { maximum: MAX_LABEL_LENGTH }
  validates :added_via, inclusion: { in: ADDED_VIA }
  validate :model_id_not_built_in
  validate :model_id_not_dated_snapshot
  validate :claude_code_id_is_floating_alias
  validate :pi_id_is_provider_qualified

  before_destroy :refuse_while_a_setting_uses_it

  scope :ordered, -> { order(:runtime, :created_at, :id) }

  class << self
    # "Model id is a dated snapshot", not Rails' "Model is a dated snapshot":
    # every surface renders full_messages.
    def human_attribute_name(attribute, options = {})
      attribute.to_s == "model_id" ? "Model id" : super
    end

    # Validate, check against the installed CLI, and save.
    #
    # @param allow_unlisted [Boolean] save even when the CLI's model list does not
    #   name the id. Without it such an id is refused, with the CLI's own note in
    #   the error, so adding one is a decision the caller makes explicitly.
    # @return [ModelCatalogEntry] persisted on success; otherwise unsaved, with
    #   errors. An `:unlisted` error on :base is the one `allow_unlisted` lifts.
    def add(runtime:, model_id:, added_via:, label: nil, requires_oauth: false, allow_unlisted: false)
      entry = new(
        runtime: runtime.to_s.strip,
        model_id: model_id.to_s.strip,
        label: label.to_s.strip.presence,
        requires_oauth: ActiveModel::Type::Boolean.new.cast(requires_oauth) || false,
        added_via: added_via
      )
      return entry unless entry.valid?

      check = ModelCatalogCliCheck.check(entry.runtime, entry.model_id)
      entry.cli_listed = check.listed
      entry.cli_version = check.cli_version
      entry.cli_note = check.note

      if check.listed == false && !ActiveModel::Type::Boolean.new.cast(allow_unlisted)
        entry.errors.add(:base, :unlisted,
          message: "#{check.note} Add it anyway only if you know the provider serves it.")
        return entry
      end

      entry.save
      entry
    rescue ActiveRecord::RecordNotUnique
      entry.errors.add(:model_id, "is already added for this runtime")
      entry
    end
  end

  def display_label
    label.presence || model_id
  end

  # A built-in entry with the same id wins in ModelCatalog, so a row a later
  # deploy has made redundant does nothing and can be removed.
  def shadowed_by_built_in?
    ModelCatalog.built_in_models_for(runtime).any? { |model| model[:id] == model_id }
  end

  def unlisted?
    cli_listed == false
  end

  # For the error on a refused destroy, which callers render.
  def destroy_refusal
    errors[:base].first
  end

  private

  def model_id_not_built_in
    return if model_id.blank? || !ModelCatalog.runtimes.include?(runtime)
    return unless new_record? && shadowed_by_built_in?

    errors.add(:model_id, "is already a built-in #{RuntimeRegistry.label_for(runtime)} model")
  end

  def model_id_not_dated_snapshot
    return unless model_id.to_s.match?(DATED_SNAPSHOT)

    errors.add(:model_id, "is a dated snapshot; add the floating alias instead, which follows new snapshots")
  end

  # ClaudeModelConfigurationAudit's rule, applied where it matters most: a
  # concrete Claude version in the Claude Code catalog is a pin that silently
  # outlives the model it names. The bare aliases already follow new releases.
  # Each `/`- or `.`-separated segment is checked, as ModelCatalogTest does, so a
  # provider-qualified or Bedrock-style pin is caught too.
  def claude_code_id_is_floating_alias
    return unless runtime == "claude_code"
    return unless model_id.to_s.split(%r{[/.]}).any? { |segment| ClaudeModelConfigurationAudit.concrete_model?(segment) }

    errors.add(:model_id, "pins a Claude version; Claude Code's aliases (opus, sonnet, haiku) already follow new releases")
  end

  # Pi's --model resolves `provider/id`. A bare id would pick a provider by fuzzy
  # match, which is not a choice to make on an operator's behalf.
  def pi_id_is_provider_qualified
    return unless runtime == "pi" && model_id.present?
    return if model_id.match?(%r{\A[^/]+/.+\z})

    errors.add(:model_id, "must be provider-qualified, like openrouter/<vendor>/<model>")
  end

  # AppSetting re-validates its default model and categorization model on every
  # save, so removing a model one of them names would break every later settings
  # write, including ones that have nothing to do with models. Change the setting
  # first. A row shadowed by a built-in entry is exempt: the id stays valid
  # without it.
  def refuse_while_a_setting_uses_it
    return if shadowed_by_built_in?
    setting = AppSetting.current(context: "ModelCatalogEntry#destroy")
    default_runtime = setting.default_runtime.presence || RuntimeRegistry::DEFAULT_RUNTIME

    if setting.default_model == model_id && default_runtime == runtime
      errors.add(:base, "#{model_id} is the session default on the Settings page. Pick another default first.")
    elsif runtime == RuntimeRegistry::DEFAULT_RUNTIME && setting.category_inference_model == model_id
      errors.add(:base, "#{model_id} is the categorization model. Pick another one on the Categorization page first.")
    end

    throw :abort if errors[:base].any?
  end
end
