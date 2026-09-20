# frozen_string_literal: true

# QuickRouterOptions — what the Quick Router's Advanced accordion may offer, and
# what a submission from it is allowed to say.
#
# Three surfaces render that accordion: the dashboard's desktop row, the
# dashboard's phone overlay, and the global chat bubble (Cmd/Ctrl+K), which the
# application layout puts on every page. They post to two different actions
# (`quick_prompt` redirects, `chat_bubble` answers JSON), so the options and the
# validation live here rather than in either controller action — a picker that
# offers a model the server would then reject is the bug this class exists to
# make impossible.
#
# Everything is read from the app's own sources of truth: the registered
# runtimes from RuntimeRegistry (via AgentRootsConfig.available_runtimes), the
# per-runtime models from ModelCatalog, and the fallback model from the same
# root → AppSetting → catalog chain Sessions::ResolveSpawnDefaults walks at
# create time.
#
# Nothing here preselects a default. Both pickers lead with a blank option that
# NAMES the fallback, so an untouched accordion posts nothing at all and the
# resolution happens once, at create time. A tab left open across a Settings
# change or a `roots.json` edit would otherwise post yesterday's default as if
# someone had chosen it.
#
# Instantiate one per request and pass it around: the router root and the
# runtime list are read once each, which matters because the chat bubble asks
# for all of this on every page in the app.
class QuickRouterOptions
  # The model a spawn on `agent_root` lands on when nobody names one, resolved the
  # way Sessions::ResolveSpawnDefaults resolves it: the root's declared model when
  # the runtime's catalog has it, else the Settings base default for the runtime
  # (which itself falls back to that runtime's catalog default). A class method
  # because the new-session form resolves the same thing for a root of its own,
  # and the two must not disagree about what "default" means.
  #
  # @param allowed_models [Array<String>, nil] the runtime's selectable model ids,
  #   when the caller already has them. Both membership tests below read that list,
  #   and looking it up costs a database read — so a caller resolving this for
  #   every registered runtime passes the lists it already loaded rather than
  #   re-reading the table once per runtime.
  # @return [String, nil]
  def self.default_model_for(agent_root, runtime, allowed_models: nil)
    allowed = allowed_models || ModelCatalog.model_ids_for(runtime)
    declared = agent_root&.default_model
    return declared if allowed.include?(declared.to_s)

    AppSetting.current.resolved_default_model_for(runtime, allowed_models: allowed)
  end

  # @return [Array<String>] the registered runtime identifiers, in registry order
  def available_runtimes
    @available_runtimes ||= AgentRootsConfig.available_runtimes
  end

  # @return [Array<Hash>] every registered runtime as ({ id:, label: }) — the
  #   harness picker's options
  def runtimes
    available_runtimes.map { |runtime| { id: runtime, label: RuntimeRegistry.label_for(runtime) } }
  end

  # The runtime a Quick Router session lands on when nobody picks one: the router
  # root's own, which has already folded in the global base default.
  #
  # @return [String]
  def default_runtime
    @default_runtime ||= router_root&.default_runtime.presence ||
      AppSetting.current.default_runtime.presence ||
      RuntimeRegistry::DEFAULT_RUNTIME
  end

  # Selectable models per runtime, as ({ id:, label:, … }) — ONE read of the
  # added-models table for the whole map, not one per runtime. The label is what
  # the picker shows, and on Codex and Pi it is the only place a model says it
  # needs a ChatGPT login or is deprecated.
  #
  # @return [Hash{String=>Array<Hash>}]
  def models_by_runtime
    @models_by_runtime ||= ModelCatalog.models_by_runtime(available_runtimes)
  end

  # Just the ids, for validating what came back. Derived from the map above rather
  # than re-read, so offer and accept cannot disagree.
  #
  # @return [Hash{String=>Array<String>}]
  def model_ids_by_runtime
    @model_ids_by_runtime ||= models_by_runtime.transform_values { |models| models.map { |m| m[:id] } }
  end

  # What "Default" resolves to per runtime — what each blank option names. Reads
  # the ids already loaded above; without that this would put the per-runtime
  # table read straight back, on every page render, through #valid_model?.
  #
  # @return [Hash{String=>String}]
  def default_models_by_runtime
    @default_models_by_runtime ||= available_runtimes.index_with do |runtime|
      self.class.default_model_for(router_root, runtime, allowed_models: model_ids_by_runtime[runtime])
    end
  end

  # The picker's options for a runtime, as [label, id] pairs.
  #
  # @return [Array<Array<String>>]
  def model_options_for(runtime)
    models_by_runtime.fetch(runtime, []).map { |m| [ m[:label], m[:id] ] }
  end

  # The map the Stimulus controller rebuilds the model <select> from when the
  # harness changes. Same lists, same labels, same order as the first paint.
  #
  # @return [Hash{String=>Array<Hash>}]
  def models_for_javascript
    models_by_runtime.transform_values { |models| models.map { |m| { id: m[:id], label: m[:label] } } }
  end

  # The harness opt-in. Blank (an untouched picker) returns nil, which leaves the
  # runtime to the ordinary chain; anything the registry does not carry also
  # returns nil, so a stale or hand-crafted value cannot write an unrunnable
  # `agent_runtime` onto the row.
  #
  # @return [String, nil]
  def resolve_runtime(requested)
    key = requested.to_s.strip
    return nil if key.blank?

    available_runtimes.include?(key) ? key : nil
  end

  # The runtime this submission will actually run on: the picked harness when it
  # survived validation, the router root's otherwise. Both the model validation
  # below and the row itself key on this.
  #
  # @return [String]
  def effective_runtime(requested)
    resolve_runtime(requested) || default_runtime
  end

  # The model opt-in, validated against `runtime` — a model id is only ever valid
  # for one runtime's catalog, so validating against the wrong one is how a Codex
  # id would land on a Claude Code session.
  #
  # @return [String, nil]
  def resolve_model(runtime, requested)
    id = requested.to_s.strip
    return nil if id.blank?

    # `fetch(runtime, [])` — never a lookup on miss. A runtime absent from the map
    # is one `available_runtimes` does not carry, so the picker offered nothing for
    # it and nothing may be accepted for it either; falling back to a catalog read
    # would accept what the picker never offered, which is the one thing this class
    # exists to prevent. The view and the Stimulus controller both degrade to an
    # empty list on the same miss.
    model_ids_by_runtime.fetch(runtime, []).include?(id) ? id : nil
  end

  # @return [Boolean] the caller named a harness and it did not survive validation
  def runtime_rejected?(requested)
    requested.to_s.strip.present? && resolve_runtime(requested).nil?
  end

  # @return [Boolean] the caller named a model and it did not survive validation
  def model_rejected?(runtime, requested)
    requested.to_s.strip.present? && resolve_model(runtime, requested).nil?
  end

  private

  # The catalog's router root, or nil when the catalog does not carry one. nil
  # rather than a raise: every reader here only wants its defaults, and the create
  # call raises AgentRootNotFoundError on that root's absence anyway. `defined?`
  # rather than `||=` so an absent root is not re-resolved on every call.
  def router_root
    return @router_root if defined?(@router_root)

    @router_root = AgentRootsConfig.find(AgentRootsConfig.router_root_name)
  end
end
