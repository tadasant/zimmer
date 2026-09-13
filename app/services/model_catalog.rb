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
#
# It is also the one place in the app's Ruby where a versioned Claude model id
# is written down. Code that calls Anthropic with a specific model — the quota
# probe — looks the id up here (#messages_api_id_for), and ModelCatalogTest
# fails on a Claude model version in any Ruby literal elsewhere under app/,
# config/ or lib/ (#85).
#
# A runtime's models come from two places (#85):
#
# - MODELS, the literal below, is the built-in baseline a fresh install ships
#   with. It alone decides each runtime's fallback default (#default_for) and the
#   quota probe's Messages API id (#messages_api_id_for), because both are read
#   into constants at boot, before anything should touch the database.
# - ModelCatalogEntry rows, which an operator adds from Settings → Models, from
#   `POST /api/v1/model_catalog_entries` or with the `manage_models` MCP tool, and
#   which #models_for appends after the built-in ones. No deploy is needed.
#
# Most new models still arrive with a CLI bump, because Pi's and Codex's pinned
# CLIs only know the models their release bundled. An added id can name a model
# the installed CLI does not know, and that would otherwise only show up when a
# session's first turn fails. So ModelCatalogEntry.add asks the installed CLI
# first (ModelCatalogCliCheck), refuses an id the CLI does not list unless the
# caller says to add it anyway, and stores the answer on the row, where each
# surface that lists added models shows it. The Claude Code ids are floating
# aliases, so a new Opus or Sonnet release reaches sessions with no change at all.
class ModelCatalog
  # Per-runtime model definitions. Within a runtime the entry flagged
  # `default: true` is the runtime's default model (falling back to the first
  # entry when none is flagged). Keys are RuntimeRegistry runtime identifiers.
  #
  # The Claude Code labels intentionally match their ids so the rendered options
  # stay aligned with Claude Code's selector aliases.
  #
  # `requires_oauth` marks models that can only be driven with an interactive
  # (ChatGPT/Claude) login rather than an API key. The UI uses it to warn when an
  # API-key-only account selects such a model. Models without the key are treated
  # as not requiring OAuth (see #requires_oauth?).
  #
  # `messages_api_id` is the model's id on Anthropic's `POST /v1/messages`, for
  # the Claude Code entries Zimmer also calls that endpoint with directly (the
  # quota probe, see QuotaCheckService::PROBE_MODEL). It is never the bare CLI
  # alias — the endpoint answers `haiku` with a 400 — and never a dated snapshot:
  # it is the floating alias there (`claude-haiku-4-5`), which follows snapshot
  # releases the way the bare alias does for the CLI. Only entries something
  # sends to the endpoint carry one; see #messages_api_id_for.
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
      { id: "haiku", label: "haiku", messages_api_id: "claude-haiku-4-5" },
      { id: "fable", label: "fable" }
    ],
    "codex" => [
      { id: "gpt-5.6-sol", label: "gpt-5.6-sol (ChatGPT auth)", requires_oauth: true },
      { id: "gpt-5.6-terra", label: "gpt-5.6-terra (default, ChatGPT auth)", default: true, requires_oauth: true },
      { id: "gpt-5.6-luna", label: "gpt-5.6-luna (fast, ChatGPT auth)", requires_oauth: true },
      { id: "gpt-5.5", label: "gpt-5.5 (ChatGPT auth)", requires_oauth: true },
      { id: "gpt-5.4", label: "gpt-5.4 (retires from ChatGPT sign-in August 31, 2026)", requires_oauth: false },
      { id: "gpt-5.4-mini", label: "gpt-5.4-mini (fast, retires from ChatGPT sign-in August 31, 2026)", requires_oauth: false },
      { id: "gpt-5.3-codex", label: "gpt-5.3-codex (deprecated)", requires_oauth: false },
      { id: "gpt-5.2-codex", label: "gpt-5.2-codex (deprecated)", requires_oauth: false }
    ],
    # Pi model ids are provider-qualified (`provider/id`), which is the form Pi's
    # `--model` flag accepts directly — so no separate `--provider` flag is needed
    # and the id a user picks is passed through verbatim. OpenRouter is itself a
    # provider, so its ids carry the vendor as well: `openrouter/anthropic/...`.
    #
    # **Everything here goes through OpenRouter, and that is one key rather than
    # several.** `openrouter` is a first-class provider in the catalog bundled
    # with the pinned Pi — no `models.json` custom-provider entry is needed — and
    # it reads `OPENROUTER_API_KEY`. Pi still honours ANTHROPIC_API_KEY and
    # OPENAI_API_KEY for `anthropic/*` and `openai/*` ids if either is set; those
    # paths are not removed, they are simply not what this deployment feeds. The
    # key is managed from the Inference page's Pi tab (ManagedSecret).
    #
    # Every id below is present in the model catalog bundled with the pinned Pi
    # CLI (see Dockerfile.base), which is the authority for what `--model`
    # resolves. Refresh discipline: re-check against `pi --list-models` when the
    # pinned Pi version is bumped, and mark a retired model deprecated in its
    # label rather than deleting it, so sessions pinned to it keep validating.
    # Note that `--list-models` only prints providers whose credential currently
    # resolves, so run it with OPENROUTER_API_KEY set or the openrouter rows are
    # silently absent.
    #
    # Nothing here requires an interactive login, so `requires_oauth` is
    # uniformly false.
    "pi" => [
      { id: "openrouter/anthropic/claude-opus-4.6", label: "claude-opus-4.6 (default)", default: true, requires_oauth: false },
      { id: "openrouter/anthropic/claude-sonnet-4.6", label: "claude-sonnet-4.6", requires_oauth: false },
      { id: "openrouter/anthropic/claude-haiku-4.5", label: "claude-haiku-4.5 (fast)", requires_oauth: false },
      { id: "openrouter/openai/gpt-5.4", label: "gpt-5.4", requires_oauth: false },
      { id: "openrouter/openai/gpt-5.4-mini", label: "gpt-5.4-mini (fast)", requires_oauth: false },
      { id: "openrouter/google/gemini-3.5-flash", label: "gemini-3.5-flash (fast)", requires_oauth: false },
      # The direct-to-vendor ids this catalog offered before OpenRouter became
      # the path. Kept, not deleted: sessions pinned to one of them still have to
      # validate (this file's own refresh discipline), and the paths still work
      # wherever ANTHROPIC_API_KEY / OPENAI_API_KEY is set. The label says which
      # key each needs, because on this deployment neither is.
      { id: "anthropic/claude-opus-4-6", label: "claude-opus-4-6 (direct, needs ANTHROPIC_API_KEY)", requires_oauth: false },
      { id: "anthropic/claude-sonnet-4-6", label: "claude-sonnet-4-6 (direct, needs ANTHROPIC_API_KEY)", requires_oauth: false },
      { id: "anthropic/claude-haiku-4-5", label: "claude-haiku-4-5 (direct, needs ANTHROPIC_API_KEY)", requires_oauth: false },
      { id: "openai/gpt-5.6-terra", label: "gpt-5.6-terra (direct, needs OPENAI_API_KEY)", requires_oauth: false },
      { id: "openai/gpt-5.4-mini", label: "gpt-5.4-mini (direct, needs OPENAI_API_KEY)", requires_oauth: false }
    ]
  }.freeze

  class << self
    # @return [Array<String>] the runtime keys that have a catalog. Adding a
    #   runtime is still a MODELS entry; only models are added at runtime.
    def runtimes
      MODELS.keys
    end

    # The built-in models, then the ones an operator added (ModelCatalogEntry) in
    # the order they were added. An added row whose id a later deploy made
    # built-in is skipped, so the built-in entry wins.
    #
    # Every hash carries `source`: "built_in" or "added". Added ones also carry
    # the CLI check stored when they were added: `cli_listed` (true, false, or nil
    # when unchecked), `cli_version` and `cli_note`.
    #
    # @param runtime [String, Symbol, nil] blank/nil/unknown resolves to the
    #   default runtime (mirroring RuntimeRegistry), so callers without an
    #   explicit runtime behave exactly as before.
    # @return [Array<Hash>] model definitions ({id:, label:, default:, source:, ...})
    def models_for(runtime)
      key = resolve(runtime)
      built_in = built_in_models_for(key)
      built_in_ids = built_in.map { |model| model[:id] }

      built_in + added_entries_for(key).reject { |entry| built_in_ids.include?(entry.model_id) }.map do |entry|
        {
          id: entry.model_id,
          label: entry.display_label,
          requires_oauth: entry.requires_oauth,
          source: "added",
          cli_listed: entry.cli_listed,
          cli_version: entry.cli_version,
          cli_note: entry.cli_note
        }
      end
    end

    # @return [Array<Hash>] only the MODELS entries for the runtime
    def built_in_models_for(runtime)
      MODELS.fetch(resolve(runtime), []).map { |model| model.merge(source: "built_in") }
    end

    # @return [Array<String>] just the model identifiers for the runtime
    def model_ids_for(runtime)
      models_for(runtime).map { |m| m[:id] }
    end

    # Read from MODELS only: an added model never becomes a runtime's fallback.
    # To make one the default for new sessions, pick it on the Settings page.
    #
    # @return [String, nil] the default model id for the runtime
    def default_for(runtime)
      models = MODELS.fetch(resolve(runtime), [])
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

    # The `POST /v1/messages` id for a Claude Code catalog model.
    #
    # Raises rather than returning nil: callers resolve it into a constant at
    # load time, so a missing or renamed entry fails the boot and the suite
    # instead of surfacing later as a failed API call.
    #
    # @param model [String, Symbol] a claude_code catalog id (e.g. "haiku")
    # @return [String] the entry's messages_api_id (e.g. "claude-haiku-4-5")
    # @raise [KeyError] when the model is not in the claude_code catalog or
    #   carries no messages_api_id
    def messages_api_id_for(model)
      entry = MODELS.fetch("claude_code").find { |m| m[:id] == model.to_s }
      entry&.dig(:messages_api_id) ||
        raise(KeyError, "ModelCatalog has no Messages API id for claude_code model #{model.inspect}")
    end

    private

    # Added models are an overlay, so an unreadable table degrades to the built-in
    # list rather than taking every model picker down with it: a container booted
    # ahead of this table's migration, or a task with no database at all.
    def added_entries_for(runtime)
      ModelCatalogEntry.where(runtime: runtime).order(:created_at, :id).to_a
    rescue ActiveRecord::StatementInvalid, ActiveRecord::ConnectionNotEstablished, ActiveRecord::NoDatabaseError => e
      Rails.logger.warn("[ModelCatalog] could not read added models for #{runtime}: #{e.class}: #{e.message}")
      raise if DatabaseTransactionState.aborted_by?(e)

      []
    end

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
