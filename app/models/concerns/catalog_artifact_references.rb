# frozen_string_literal: true

# The catalog-artifact reference columns — the jsonb string arrays naming MCP
# servers, skills, hooks and plugins — that both Session and Trigger carry.
#
# Every one of them wants the same three things: reject a non-array, reject a
# name the AIR catalog does not know, and (for a long-lived row like a Trigger)
# quietly drop a name the catalog stopped knowing. Written out by hand that is
# two validators and a thirty-line heal per column per model, and the copies
# drifted: a Trigger validated its skills, hooks and plugins at save but not its
# MCP servers, so the same typo was a form error in one field and a silent
# fire-time rewrite plus an alert in the next one over.
#
# Declare each column once instead:
#
#   include CatalogArtifactReferences
#   catalog_reference :catalog_skills, config: SkillsConfig, noun: "skill",
#                                      alert_noun: "catalog skill"
#
# which registers `<attr>_must_be_array` and `<attr>_must_exist_in_catalog` (the
# latter scoped to `<attr>_changed?`, so an untouched stale value on an existing
# row never blocks an unrelated save) and defines `heal_stale_<attr>!`.
#
# The heal is generated for every declaration, but only Trigger calls it — from
# `#create_session!`, via `#heal_catalog_references!`. A Session's skill list is
# scrubbed on a different schedule and by a different owner, `air prepare` time
# in AirPrepareService#scrubbed_catalog_skills.
#
# `agent_root_name` is deliberately NOT one of these. It is a single name rather
# than a list, and its heal looks up a successor root and can raise — see
# Trigger#heal_stale_agent_root! and zimmer#448.
module CatalogArtifactReferences
  extend ActiveSupport::Concern

  # One declared column, plus the words the messages about it are built from.
  #
  # `noun` is the singular as it reads in a validation error and in the tail of
  # the heal alert ("contains invalid server(s)", "the remaining servers");
  # `alert_noun` is the singular as it reads in the alert's subject ("stale MCP
  # server(s) removed", "stale catalog skill(s) removed"). They differ because
  # the two sentences were written by different hands, and the dedup keys and
  # alert titles they produce are load-bearing.
  #
  # The config facade is held by NAME and constantized per call: the *Config
  # classes are autoloaded, and pinning the class object in a class_attribute
  # would keep a stale copy alive across a development reload.
  Reference = Struct.new(:attribute, :config_name, :noun, :alert_noun, :dedup_noun, keyword_init: true) do
    def config = config_name.constantize
    def plural = noun.pluralize
    def heal_method = :"heal_stale_#{attribute}!"
  end

  included do
    # Accumulated per including class, in declaration order.
    class_attribute :catalog_artifact_references, instance_writer: false, default: [].freeze

    # What a heal alert reports as its origin. Only a class that actually heals
    # needs to set it, via `heals_catalog_references_in`.
    class_attribute :catalog_heal_alert_source, instance_writer: false, default: nil
  end

  class_methods do
    # Declare a catalog-artifact column.
    #
    # @param attribute [Symbol] the jsonb array column
    # @param config [Class] the catalog facade — must answer `.all` and `.exists?`
    # @param noun [String] singular, as it reads in a validation error
    # @param alert_noun [String] singular, as it reads in a heal alert's subject
    # @param dedup_noun [String] the segment of the heal alert's dedup_key;
    #   defaults to the plural of `noun`
    def catalog_reference(attribute, config:, noun:, alert_noun: noun, dedup_noun: nil)
      reference = Reference.new(
        attribute: attribute.to_sym,
        config_name: config.name,
        noun: noun,
        alert_noun: alert_noun,
        dedup_noun: dedup_noun || noun.pluralize
      ).freeze
      self.catalog_artifact_references = (catalog_artifact_references + [ reference ]).freeze

      define_method(:"#{attribute}_must_be_array") { catalog_reference_must_be_array(reference) }
      define_method(:"#{attribute}_must_exist_in_catalog") { catalog_reference_must_exist_in_catalog(reference) }
      define_method(reference.heal_method) { heal_stale_catalog_reference!(reference) }
      private :"#{attribute}_must_be_array", :"#{attribute}_must_exist_in_catalog", reference.heal_method

      validate :"#{attribute}_must_be_array"
      # Scoped to the change so that a row persisted before an artifact vanished
      # from the catalog still saves on an edit that does not touch this column.
      # Healing, not validation, is what cleans those up.
      validate :"#{attribute}_must_exist_in_catalog", if: :"#{attribute}_changed?"
    end

    # Where this model heals, for the `source:` on the alerts it raises.
    def heals_catalog_references_in(source)
      self.catalog_heal_alert_source = source
    end
  end

  # Drop every declared reference the catalog no longer knows about, in
  # declaration order, persisting and alerting on each kind that changed.
  def heal_catalog_references!
    catalog_artifact_references.each { |reference| heal_stale_catalog_reference!(reference) }
  end

  private

  def catalog_reference_must_be_array(reference)
    value = public_send(reference.attribute)
    return if value.nil? || value.is_a?(Array)

    errors.add(reference.attribute, "must be an array")
  end

  def catalog_reference_must_exist_in_catalog(reference)
    value = public_send(reference.attribute)
    return if value.nil? || !value.is_a?(Array)

    # Blank entries are dropped rather than rejected: Rails params send [""] for
    # an empty multi-select.
    invalid = value.reject(&:blank?).reject { |entry| reference.config.exists?(entry) }
    return if invalid.empty?

    errors.add(reference.attribute, "contains invalid #{reference.noun}(s): #{invalid.join(', ')}")
  end

  # Remove references the catalog no longer knows about and persist the
  # survivors, so the stale name is encountered — and alerted on — once.
  #
  # @return [Array<String>] the references that remain
  def heal_stale_catalog_reference!(reference)
    current = public_send(reference.attribute)
    return current if current.blank?
    # Load-bearing. A failed `air resolve` degrades every catalog facade to an
    # empty list (zimmer#112), at which point EVERY reference looks stale and
    # healing would strip the column on every row it touched. An empty catalog
    # is never evidence that a reference is gone.
    return current if reference.config.all.empty?

    non_blank = current.reject(&:blank?)
    stale = non_blank.reject { |entry| reference.config.exists?(entry) }
    return current if stale.empty?

    valid = non_blank - stale
    update_column(reference.attribute, valid)

    label = catalog_reference_model_label

    Rails.logger.warn(
      "[#{self.class.name}##{reference.heal_method}] Removed stale #{reference.alert_noun}(s) #{stale.inspect} " \
      "from #{label.downcase} '#{catalog_reference_display_name}' (ID: #{id}). " \
      "Remaining #{reference.plural}: #{valid.inspect}"
    )

    AlertService.raise_alert(
      "#{label} self-healed: stale #{reference.alert_noun}(s) removed",
      details: "#{label} *#{catalog_reference_display_name}* (ID: #{id}) referenced " \
               "#{reference.alert_noun}(s) that no longer exist:\n" \
               "• Removed: #{stale.join(', ')}\n" \
               "• Remaining: #{valid.empty? ? '(none)' : valid.join(', ')}\n\n" \
               "The stale reference(s) have been removed from the #{label.downcase}. " \
               "The session will proceed with the remaining #{reference.plural}.\n\n" \
               "<#{AppUrl.base_url}/#{self.class.model_name.route_key}/#{id}|View #{label.downcase} in Zimmer>",
      source: catalog_heal_alert_source || "#{self.class.name}#heal_catalog_references!",
      dedup_key: "#{label.downcase}_stale_#{reference.dedup_noun}_#{id}"
    )

    valid
  end

  # "Trigger", "Session" — how the model names itself in a heal alert.
  def catalog_reference_model_label
    self.class.model_name.human
  end

  # How the row names itself in a heal alert. Trigger has a `name`; anything
  # without one falls back to its id.
  def catalog_reference_display_name
    try(:name).presence || "##{id}"
  end
end
