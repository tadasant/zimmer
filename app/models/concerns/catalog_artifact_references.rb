# frozen_string_literal: true

# The catalog-artifact reference columns — the jsonb string arrays naming MCP
# servers, skills, hooks and plugins — that both Session and Trigger carry.
#
# Every one of them wants the same three things: reject a non-array, reject a
# name the AIR catalog does not know, and (for a long-lived row like a Trigger)
# keep firing when the catalog stops knowing one. Written out by hand that is
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
# row never blocks an unrelated save), and defines `heal_stale_<attr>!` and the
# `resolvable_<attr>` reader a fire spawns from.
#
# The heal is generated for every declaration, but only Trigger calls it — from
# `#create_session!`, via `#heal_catalog_references!`. A Session's skill list is
# scrubbed on a different schedule and by a different owner, `air prepare` time
# in AirPrepareService#scrubbed_catalog_skills.
#
# --- The heal keeps the name it cannot resolve (zimmer#853) ------------------
#
# It used to `update_column` the survivors, deleting the unresolvable name from
# the row. A catalog RENAME — the common case, far commoner than an outright
# deletion — is indistinguishable from a deletion here: the old slug just stops
# resolving. Destroying it on that reading made the rename unrecoverable from
# the trigger's side. When `slack-workspace` became `slack-zimmer` on
# 2026-09-03, six live triggers lost Slack one fire at a time over the following
# hours, and the only surviving record of what each had named was the alert.
#
# So the heal is not destructive any more. It:
#
#   * leaves the column exactly as the operator wrote it, so the old name is
#     still there to remap, and so a reverted rename or a re-added artifact
#     starts working again on the very next fire with no intervention at all;
#   * filters the unresolvable names out IN MEMORY, and the fire spawns from
#     `resolvable_<attr>` — a session never receives a name the catalog cannot
#     resolve, which is what "still drop it" means for a genuine deletion;
#   * records what is currently unresolvable in `unresolved_catalog_references`,
#     so it announces a name ONCE rather than on every fire forever. Preserving
#     without that bookkeeping would turn one alert into an hourly one.
#
# The row is left mid-repair on purpose: an operator's judgement is what decides
# whether a vanished name was renamed (point it at the successor) or deleted
# (take it off). Neither answer is derivable here — unlike `agent_root_name`,
# which has a git_root + subdirectory match to find its successor with.
#
# `agent_root_name` is deliberately NOT one of these. It is a single name rather
# than a list, and its heal looks up a successor root and can raise — see
# Trigger#heal_stale_agent_root! and zimmer#448.
module CatalogArtifactReferences
  extend ActiveSupport::Concern

  # One declared column, plus the words the messages about it are built from.
  #
  # `noun` is the singular as it reads in a validation error and in the body of
  # the heal alert ("contains invalid server(s)", "if the server was RENAMED");
  # `alert_noun` is the singular as it reads in the alert's subject ("MCP
  # server(s) missing from the catalog", "catalog skill(s) missing from the
  # catalog"). They differ because the two sentences were written by different
  # hands, and the alert titles they produce are load-bearing.
  #
  # The config facade is held by NAME and constantized per call: the *Config
  # classes are autoloaded, and pinning the class object in a class_attribute
  # would keep a stale copy alive across a development reload.
  Reference = Struct.new(:attribute, :config_name, :noun, :alert_noun, keyword_init: true) do
    def config = config_name.constantize
    def heal_method = :"heal_stale_#{attribute}!"
    def resolvable_method = :"resolvable_#{attribute}"
    # Key under which `unresolved_catalog_references` tracks this column. jsonb
    # keys are strings; the attribute is a symbol.
    def tracking_key = attribute.to_s
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
    def catalog_reference(attribute, config:, noun:, alert_noun: noun)
      reference = Reference.new(
        attribute: attribute.to_sym,
        config_name: config.name,
        noun: noun,
        alert_noun: alert_noun
      ).freeze
      self.catalog_artifact_references = (catalog_artifact_references + [ reference ]).freeze

      define_method(:"#{attribute}_must_be_array") { catalog_reference_must_be_array(reference) }
      define_method(:"#{attribute}_must_exist_in_catalog") { catalog_reference_must_exist_in_catalog(reference) }
      define_method(reference.heal_method) { heal_stale_catalog_reference!(reference) }
      private :"#{attribute}_must_be_array", :"#{attribute}_must_exist_in_catalog", reference.heal_method

      # PUBLIC, unlike the three above: this is what a fire hands to a session,
      # and it is deliberately not the column. See #catalog_reference_resolvable.
      define_method(reference.resolvable_method) { catalog_reference_resolvable(reference) }

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

  # Whether a fire has found that the catalog cannot resolve this name.
  #
  # Reads the recorded bookkeeping rather than asking the catalog, so it is free
  # to call per name in a list view — at the cost of reporting only what fires
  # have actually found. A row that has not fired since the rename says false.
  #
  # @param attribute [Symbol, String] one of the declared reference columns
  # @param name [String]
  def unresolved_catalog_reference?(attribute, name)
    return false unless has_attribute?(:unresolved_catalog_references)

    (unresolved_catalog_references || {}).dig(attribute.to_s, name).present?
  end

  # Reconcile every declared reference against the catalog, in declaration
  # order, announcing each kind that has newly stopped resolving. Nothing on the
  # row is rewritten — see the module comment.
  #
  # @return [Hash{Symbol => Array<String>}] attribute => the resolvable subset
  def heal_catalog_references!
    catalog_artifact_references.index_with { |reference| heal_stale_catalog_reference!(reference) }
      .transform_keys(&:attribute)
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

    config = reference.config
    # Blank entries are dropped rather than rejected: Rails params send [""] for
    # an empty multi-select.
    invalid = value.reject(&:blank?).reject { |entry| config.exists?(entry) }
    return if invalid.empty?

    errors.add(reference.attribute, "contains invalid #{reference.noun}(s): #{invalid.join(', ')}")
  end

  # The column's entries, minus the blanks. Rails params send [""] for an empty
  # multi-select, and nothing downstream has a use for one.
  #
  # @return [Array<String>]
  def catalog_reference_values(reference)
    (public_send(reference.attribute) || []).reject(&:blank?)
  end

  # The subset of a reference column the catalog resolves right now — what a
  # fire hands to the session it spawns, and never the raw column.
  #
  # @return [Array<String>]
  def catalog_reference_resolvable(reference)
    values = catalog_reference_values(reference)
    return values if values.empty?

    config = reference.config
    # The same load-bearing guard the heal makes, for the same reason: against a
    # catalog that failed to load every name looks unresolvable, and filtering
    # on that reading would hand every session an empty list. Pass the names
    # through instead and let session creation fail loudly on them.
    return values if config.all.empty?

    values.select { |entry| config.exists?(entry) }
  end

  # Reconcile one reference column against the catalog: work out which names it
  # can no longer resolve, announce the ones that are new, and return the ones
  # that still resolve.
  #
  # Deliberately writes nothing to the column itself. What the operator wrote
  # stays written; see the module comment for why a rename makes that the only
  # safe answer.
  #
  # @return [Array<String>] the references that still resolve
  def heal_stale_catalog_reference!(reference)
    values = catalog_reference_values(reference)
    config = reference.config
    # Load-bearing. A catalog that fails to load leaves the facade an empty list
    # (zimmer#112), at which point EVERY reference looks stale. Announcing on
    # that reading would page once per trigger for a fault that is nothing to do
    # with any of them, and record a deployment-wide outage as per-row state.
    # An empty catalog is never evidence that a reference is gone.
    return values if config.all.empty?

    unresolvable = values.reject { |entry| config.exists?(entry) }
    resolvable = values - unresolvable

    # Logged on EVERY fire that finds one, not only the fire that announces it.
    # The announcement below fires once per newly-unresolvable set, so the WARN —
    # shipped to the obs stack and queryable, but not a page — is what makes a
    # trigger running degraded visible for as long as it is running degraded.
    log_unresolved_catalog_reference(reference, unresolvable, resolvable) if unresolvable.any?

    # Called even when nothing is unresolvable: that is what clears the sidecar
    # when a name starts resolving again, and a cleared entry is what lets the
    # same name announce afresh if it goes away a second time.
    newly = record_unresolved_catalog_references!(reference, unresolvable)
    announce_unresolved_catalog_reference(reference, unresolvable: unresolvable, resolvable: resolvable) if newly.any?

    resolvable
  end

  # Update the sidecar to say exactly which of this column's names are
  # unresolvable right now, and answer which of them are newly so.
  #
  # The sidecar is bookkeeping, not an audit log: an entry is dropped as soon as
  # its name resolves again or leaves the column, which is what lets a name that
  # goes stale a second time announce a second time.
  #
  # @return [Array<String>] the names to announce — empty when there is nothing
  #   new to say
  def record_unresolved_catalog_references!(reference, unresolvable)
    # A DEGRADED resolve serves a last-known-good tree that can predate a
    # rename, so a name that is perfectly valid today can look unresolvable to
    # this fire. Filtering in memory is still right — the fire has to spawn
    # something, and a name this catalog cannot resolve would fail session
    # validation anyway — but writing that reading down, or paging a human with
    # it, is not. Same call AirPrepareService#persist_scrubbed_catalog_skills
    # makes, and the second half of zimmer#853. The WARN in the caller still
    # fires, so the filtering is not silent.
    #
    # First, so that it also covers a model with no sidecar to write.
    return [] if AirCatalogService.degraded?

    # A model that declares references but never heals (Session) carries no
    # sidecar. Nothing calls this there; if anything ever does, announcing every
    # time beats raising on a column that does not exist.
    return unresolvable unless has_attribute?(:unresolved_catalog_references)

    tracked = unresolved_catalog_references || {}
    previously = tracked[reference.tracking_key] || {}
    newly = unresolvable - previously.keys

    first_seen_at = Time.current.iso8601
    currently = previously.slice(*unresolvable).merge(newly.index_with { first_seen_at })
    return newly if currently == previously

    updated = currently.empty? ? tracked.except(reference.tracking_key) : tracked.merge(reference.tracking_key => currently)
    # update_column for the same reason the model's other bookkeeping writes use
    # it: this is not a change to the trigger's configuration and must not run
    # validations, callbacks or touch `updated_at`.
    update_column(:unresolved_catalog_references, updated)

    newly
  end

  # The durable, non-paging record: one WARN per fire that finds an unresolvable
  # name, whether or not this fire announces it.
  def log_unresolved_catalog_reference(reference, unresolvable, resolvable)
    label = catalog_reference_model_label

    Rails.logger.warn(
      "[#{self.class.name}##{reference.heal_method}] The catalog cannot resolve " \
      "#{reference.alert_noun}(s) #{unresolvable.inspect} named by #{label.downcase} " \
      "'#{catalog_reference_display_name}' (ID: #{id})#{' (catalog is DEGRADED, so this may be a stale reading)' if AirCatalogService.degraded?}. " \
      "They are KEPT on the #{label.downcase} and filtered out of the sessions it spawns. " \
      "Spawning with: #{resolvable.inspect}"
    )
  end

  # Say — once per set of unresolvable names — that this row names something the
  # catalog cannot resolve.
  #
  # The alert reports the whole current picture rather than only the name that
  # tripped it, because an operator reading it is about to edit the row and
  # wants every name on it that does not resolve.
  def announce_unresolved_catalog_reference(reference, unresolvable:, resolvable:)
    label = catalog_reference_model_label

    details = "#{label} #{catalog_reference_display_name} (ID: #{id}) references " \
              "#{reference.alert_noun}(s) the catalog cannot resolve:\n" \
              "• Unresolvable: #{unresolvable.join(', ')}\n" \
              "• Still resolving: #{resolvable.empty? ? '(none)' : resolvable.join(', ')}\n\n" \
              "The reference is KEPT on the #{label.downcase} — nothing has been deleted — and the " \
              "sessions it spawns run without it until this is settled. If the #{reference.noun} was " \
              "RENAMED, edit the #{label.downcase} to name its replacement; if it was DELETED, remove " \
              "it. Restoring the name to the catalog also fixes it, on the next fire, with no edit.\n\n" \
              "#{AppUrl.base_url}/#{self.class.model_name.route_key}/#{id}"
    source = catalog_heal_alert_source || "#{self.class.name}#heal_catalog_references!"

    # .error, where the line above this method logs the same condition at .warn on
    # every fire. The ERROR record is the page, and it is raised only on the fire
    # that announces — the bookkeeping in #record_unresolved_catalog_references!
    # makes that once per newly-unresolvable set.
    Rails.logger.error("[#{source}] #{details}")
    ErrorReporter.report_message(
      "#{label} degraded: #{reference.alert_noun}(s) missing from the catalog",
      level: :error,
      context: {
        source: source,
        details: details,
        record_id: id,
        unresolvable: unresolvable.sort.join(", ")
      }
    )
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
