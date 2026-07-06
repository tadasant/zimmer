# frozen_string_literal: true

# ModelCatalog — the authoritative list of models selectable per agent runtime.
#
# The set of models a user may pick is a property of the *runtime*, not of any
# individual agent root (a root only declares a single `default_model`). This
# catalog is the single source of truth the new-session form, the detail-page
# model editor, and the REST API all consult to populate options and validate
# selections.
#
# Adding a runtime (e.g. the OpenAI Codex catalog) is pure data here — a new
# MODELS entry — requiring no UI or controller plumbing changes. That data-only
# seam is the reason this class exists. A runtime's catalog is reachable here as
# soon as its MODELS entry exists, even before RuntimeRegistry registers the
# runtime's implementation bundle (see #resolve), so the data layer can land
# ahead of the adapter that consumes it.
class ModelCatalog
  # Per-runtime model definitions. Within a runtime the entry flagged
  # `default: true` is the runtime's default model (falling back to the first
  # entry when none is flagged). Keys are RuntimeRegistry runtime identifiers.
  #
  # The Claude Code labels intentionally match their ids so the rendered options
  # read exactly as they did before this catalog existed (opus/sonnet/haiku).
  #
  # `requires_oauth` marks models that can only be driven with an interactive
  # (ChatGPT/Claude) login rather than an API key. The UI uses it to warn when an
  # API-key-only account selects such a model. Models without the key are treated
  # as not requiring OAuth (see #requires_oauth?).
  #
  # Codex (GPT) model-catalog refresh discipline: this list mirrors the models
  # OpenAI publishes at https://developers.openai.com/codex/models — bump it when
  # OpenAI ships new models or retires old ones; see also the `ao-upgrade-codex`
  # skill. Mark a model `deprecated: true` (in its label) rather than removing it
  # immediately so sessions pinned to it keep validating.
  MODELS = {
    "claude_code" => [
      { id: "opus", label: "opus", default: true },
      { id: "sonnet", label: "sonnet" },
      { id: "haiku", label: "haiku" }
    ],
    "codex" => [
      { id: "gpt-5.5", label: "gpt-5.5 (default, ChatGPT auth)", default: true, requires_oauth: true },
      { id: "gpt-5.4", label: "gpt-5.4", requires_oauth: false },
      { id: "gpt-5.4-mini", label: "gpt-5.4-mini (fast)", requires_oauth: false },
      { id: "gpt-5.3-codex", label: "gpt-5.3-codex", requires_oauth: false },
      { id: "gpt-5.2-codex", label: "gpt-5.2-codex (deprecated)", requires_oauth: false }
    ]
  }.freeze

  class << self
    # @param runtime [String, Symbol, nil] blank/nil/unknown resolves to the
    #   default runtime (mirroring RuntimeRegistry), so callers without an
    #   explicit runtime behave exactly as before.
    # @return [Array<Hash>] model definitions ({id:, label:, default:}) for the runtime
    def models_for(runtime)
      MODELS.fetch(resolve(runtime), [])
    end

    # @return [Array<String>] just the model identifiers for the runtime
    def model_ids_for(runtime)
      models_for(runtime).map { |m| m[:id] }
    end

    # @return [String, nil] the default model id for the runtime
    def default_for(runtime)
      models = models_for(runtime)
      (models.find { |m| m[:default] } || models.first)&.dig(:id)
    end

    # @return [Boolean] whether `model` is a valid identifier for the runtime
    def valid_model?(runtime, model)
      model_ids_for(runtime).include?(model.to_s)
    end

    # @return [Boolean] whether the model can only be driven via an interactive
    #   (OAuth) login rather than an API key. False for unknown models and for
    #   models whose entry omits the flag.
    def requires_oauth?(runtime, model)
      entry = models_for(runtime).find { |m| m[:id] == model.to_s }
      entry ? !!entry[:requires_oauth] : false
    end

    private

    # Normalize a runtime arg to its canonical catalog key.
    #
    # ModelCatalog is the source of truth for its own keys: a runtime that has a
    # MODELS entry resolves to itself, so its catalog is reachable even before
    # RuntimeRegistry registers the runtime's implementation bundle. Other values
    # (blank/nil/unknown) defer to RuntimeRegistry, falling back to the default
    # runtime so catalog lookups never raise.
    def resolve(runtime)
      key = runtime.presence&.to_s
      return key if key && MODELS.key?(key)

      RuntimeRegistry.resolve_key(runtime)
    rescue KeyError
      RuntimeRegistry::DEFAULT_RUNTIME
    end
  end
end
