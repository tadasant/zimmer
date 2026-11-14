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
# Most new Pi models arrive with a CLI bump, because Pi's pinned CLI only knows
# the models its release bundled. An added id can name a model
# the installed CLI does not know, and that would otherwise only show up when a
# session's first turn fails. So ModelCatalogEntry.add asks the installed CLI
# first (ModelCatalogCliCheck), refuses an id the CLI does not list unless the
# caller says to add it anyway, and stores the answer on the row, where each
# surface that lists added models shows it. The Claude Code ids are floating
# aliases and the Codex ids are model families resolved at launch
# (CodexModelResolver), so a new Opus, Sonnet or GPT release in an existing
# family reaches sessions with no change at all.
class ModelCatalog
  # Claude Code's `--effort` values, lowest to highest.
  CLAUDE_CODE_EFFORT_LEVELS = %w[low medium high xhigh max].freeze

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
  # The Codex ids are model *families*, not versions — `sol` (frontier), `terra`
  # (balanced) and `luna` (fast) — the Codex counterpart to the Claude Code
  # aliases. The Codex CLI has no floating alias of its own, so
  # CodexModelResolver turns a family into the newest `gpt-<version>-<family>`
  # slug the installed CLI lists, at every launch. A new OpenAI release in an
  # existing family needs no change here. ModelCatalogTest fails on a version
  # number in a Codex built-in id; an id that has to stay pinned is an added model
  # (Settings → Models), which is passed to `-m` verbatim.
  #
  # `effort_levels` and `default_effort` describe the reasoning-effort setting a
  # session can carry in `config["effort"]` (see #effort_levels_for). They are
  # copied from the model table bundled with Claude Code CLI 2.1.289, whose
  # aliases resolve to the models named in each comment, and agree with
  # https://platform.claude.com/docs/en/build-with-claude/effort.
  # `default_effort` is what the CLI runs when no `--effort` is passed, so it is
  # what Zimmer reports for a session that named none — Zimmer never passes it
  # itself, so a session that names no level always gets the CLI's real default
  # even when this copy is stale. The CLI is not pinned: ClaudeCodeUpdateJob runs
  # `claude update` daily and the aliases float, so a release can change either
  # field with no Zimmer deploy. Refresh discipline: re-check both against the
  # CLI's model table whenever a new model lands behind an alias. An entry
  # without `effort_levels` takes no effort setting.

  # The Claude models Live Mode's experimental voice engines reason with, by
  # their Messages API id, labelled for the Live settings (LiveSetting
  # `voice_claude_model`; LiveConversations::ClaudeDelegate). The ids are the
  # keys of the price table's `anthropic` section (config/live_voice_prices.yml),
  # so a model added here needs a price there or it is recorded unpriced.
  LIVE_CLAUDE_MODELS = {
    "claude-sonnet-5-5" => "claude-sonnet-5-5 — fast, $2/$10 per MTok (default)",
    "claude-opus-5-5" => "claude-opus-5-5 — strongest, $4/$20 per MTok",
    "claude-haiku-5-5" => "claude-haiku-5-5 — cheapest, $0.10/$0.50 per MTok"
  }.freeze
  LIVE_CLAUDE_DEFAULT = LIVE_CLAUDE_MODELS.keys.first

  MODELS = {
    "claude_code" => [
      # claude-opus-5-5
      { id: "opus", label: "opus", default: true, effort_levels: CLAUDE_CODE_EFFORT_LEVELS, default_effort: "medium" },
      # claude-sonnet-5-5. The API default is `high`; Claude Code ships `medium`,
      # which is what the docs recommend for agentic coding on this model.
      { id: "sonnet", label: "sonnet", effort_levels: CLAUDE_CODE_EFFORT_LEVELS, default_effort: "medium" },
      # claude-haiku-4-5 does not support the effort parameter.
      { id: "haiku", label: "haiku", messages_api_id: "claude-haiku-4-5" },
      # claude-fable-5-1
      { id: "fable", label: "fable", effort_levels: CLAUDE_CODE_EFFORT_LEVELS, default_effort: "high" }
    ],
    "codex" => [
      { id: "sol", label: "sol (latest frontier, ChatGPT plans that offer it)", requires_oauth: true },
      { id: "terra", label: "terra (latest balanced, default, ChatGPT auth)", default: true, requires_oauth: true },
      { id: "luna", label: "luna (latest fast, ChatGPT auth)", requires_oauth: true }
    ],
    # Pi model ids are provider-qualified (`provider/id`), which is the form Pi's
    # `--model` flag accepts directly — so no separate `--provider` flag is needed
    # and the id a user picks is passed through verbatim. OpenRouter is itself a
    # provider, so its ids carry the vendor as well: `openrouter/~anthropic/...`.
    #
    # **Everything here goes through OpenRouter, and that is one key rather than
    # several.** `openrouter` is a first-class provider in the catalog bundled
    # with the pinned Pi — no `models.json` custom-provider entry is needed — and
    # it reads `OPENROUTER_API_KEY`. Pi still honours ANTHROPIC_API_KEY and
    # OPENAI_API_KEY for `anthropic/*` and `openai/*` ids if either is set; those
    # paths are not removed, they are simply not what this deployment feeds. The
    # key lives in the secret store; the Inference page's Pi tab says whether it is set.
    #
    # **Every id below is one of OpenRouter's floating `~<vendor>/<family>-latest`
    # aliases**, the Pi counterpart to the Claude Code aliases: OpenRouter routes
    # each to the newest model in its family, so a new Opus, Gemini or Grok
    # reaches sessions with no change here. ModelCatalogTest fails on a version
    # number in a Pi built-in id.
    #
    # The list is the families that are in BOTH OpenRouter's live listing
    # (`GET https://openrouter.ai/api/v1/models`, so the id does not 404) and the
    # model catalog bundled with the pinned Pi CLI (see Dockerfile.base), which is
    # what `--model` resolves against — an id Pi does not list still runs, but on
    # metadata Pi borrows from another model. OpenRouter's GPT tier aliases
    # (`~openai/gpt-terra-latest` and friends) are live but not yet in the pinned
    # Pi's catalog, so they are not offered; add them when a Pi bump lists them.
    # Refresh discipline: re-check both lists when the pinned Pi version is bumped.
    # Note that `pi --list-models` only prints providers whose credential
    # currently resolves, so run it with OPENROUTER_API_KEY set (any value works
    # with `--offline`) or the openrouter rows are silently absent.
    #
    # Nothing here requires an interactive login, so `requires_oauth` is
    # uniformly false.
    "pi" => [
      { id: "openrouter/~anthropic/claude-opus-latest", label: "claude-opus-latest (default)", default: true, requires_oauth: false },
      { id: "openrouter/~anthropic/claude-sonnet-latest", label: "claude-sonnet-latest", requires_oauth: false },
      { id: "openrouter/~anthropic/claude-haiku-latest", label: "claude-haiku-latest (fast)", requires_oauth: false },
      { id: "openrouter/~anthropic/claude-fable-latest", label: "claude-fable-latest", requires_oauth: false },
      { id: "openrouter/~openai/gpt-mini-latest", label: "gpt-mini-latest (fast)", requires_oauth: false },
      { id: "openrouter/~google/gemini-pro-latest", label: "gemini-pro-latest", requires_oauth: false },
      { id: "openrouter/~google/gemini-flash-latest", label: "gemini-flash-latest (fast)", requires_oauth: false },
      { id: "openrouter/~x-ai/grok-latest", label: "grok-latest", requires_oauth: false },
      { id: "openrouter/~moonshotai/kimi-latest", label: "kimi-latest", requires_oauth: false },
      { id: "openrouter/~z-ai/glm-latest", label: "glm-latest", requires_oauth: false }
    ]
  }.freeze

  # Ids a runtime's built-ins used to pin, mapped to the version-free built-in
  # that replaces each. Sessions, the Settings default and agent roots' declared
  # `default_model` stored before the switch still hold them, so they stay valid
  # (#valid_model?) without being offered in any picker, and are stored as their
  # replacement wherever Zimmer writes a model (#canonical_model_id). A Codex
  # legacy id launches as its family's latest model (#codex_family_for); the
  # replacement for a retired one is what the Codex CLI's own `upgrade` marker
  # names (gpt-5.4 → terra, gpt-5.4-mini → luna).
  #
  # A nil replacement keeps an id valid, launched verbatim, with no family alias
  # to move it to: OpenRouter's GPT flagship (no alias the pinned Pi lists) and
  # Pi's direct-to-vendor ids, which need a key this deployment does not feed.
  LEGACY_MODEL_ALIASES = {
    "codex" => {
      "gpt-5.6-sol" => "sol",
      "gpt-5.6-terra" => "terra",
      "gpt-5.6-luna" => "luna",
      "gpt-5.5" => "sol",
      "gpt-5.4" => "terra",
      "gpt-5.4-mini" => "luna",
      "gpt-5.3-codex" => "terra",
      "gpt-5.2-codex" => "terra"
    },
    "pi" => {
      "openrouter/anthropic/claude-opus-4.6" => "openrouter/~anthropic/claude-opus-latest",
      "openrouter/anthropic/claude-sonnet-4.6" => "openrouter/~anthropic/claude-sonnet-latest",
      "openrouter/anthropic/claude-haiku-4.5" => "openrouter/~anthropic/claude-haiku-latest",
      "openrouter/openai/gpt-5.4-mini" => "openrouter/~openai/gpt-mini-latest",
      "openrouter/google/gemini-3.5-flash" => "openrouter/~google/gemini-flash-latest",
      "openrouter/openai/gpt-5.4" => nil,
      "anthropic/claude-opus-4-6" => nil,
      "anthropic/claude-sonnet-4-6" => nil,
      "anthropic/claude-haiku-4-5" => nil,
      "openai/gpt-5.6-terra" => nil,
      "openai/gpt-5.4-mini" => nil
    }
  }.freeze

  class << self
    # @return [Array<String>] the runtime keys that have a catalog. Adding a
    #   runtime is a MODELS entry; only models are added at runtime.
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

      merge_added(built_in, built_in_ids, added_entries_for(key))
    end

    # @return [Array<Hash>] only the MODELS entries for the runtime
    def built_in_models_for(runtime)
      MODELS.fetch(resolve(runtime), []).map { |model| model.merge(source: "built_in") }
    end

    # @return [Array<String>] just the model identifiers for the runtime
    def model_ids_for(runtime)
      models_for(runtime).map { |m| m[:id] }
    end

    # The same lists as #models_for, for several runtimes at once, on ONE read of
    # the added-models table instead of one per runtime. Built by the same
    # #merge_added as #models_for, so the two cannot disagree.
    #
    # The Quick Router's harness picker needs every registered runtime's models in
    # the same render, and the chat bubble renders on every page in the app — so
    # the per-runtime `where(runtime:)` would be one query per runtime on every
    # request in Zimmer.
    #
    # @param runtimes [Array<String>] runtime identifiers
    # @return [Hash{String=>Array<Hash>}] keyed by the identifiers as given
    def models_by_runtime(runtimes)
      added = all_added_entries.group_by(&:runtime)

      runtimes.index_with do |runtime|
        key = resolve(runtime)
        built_in = built_in_models_for(key)
        merge_added(built_in, built_in.map { |m| m[:id] }, added.fetch(key, []))
      end
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
    #   — one a picker offers, or a legacy id (LEGACY_MODEL_ALIASES) still
    #   stored on an older session or setting
    def valid_model?(runtime, model)
      model_ids_for(runtime).include?(model.to_s) || legacy_model?(runtime, model)
    end

    # The id to store for `model`: the version-free built-in that replaced it when
    # it is a legacy pinned id, otherwise `model` itself. An operator-added model
    # with a legacy id is a deliberate pin and stays as it is.
    #
    # @return [String, nil]
    def canonical_model_id(runtime, model, allowed_models: nil)
      return model if model.blank?

      allowed = allowed_models || model_ids_for(runtime)
      return model.to_s if allowed.include?(model.to_s)

      legacy_alias_for(runtime, model) || model.to_s
    end

    # The Codex family (`sol`, `terra`, `luna`) a codex model id launches as, or
    # nil when it is passed to `-m` verbatim: a built-in family id, or a legacy
    # pinned id that no operator re-added. See CodexModelResolver.
    #
    # @return [String, nil]
    def codex_family_for(model)
      id = model.to_s
      return id if MODELS.fetch("codex").any? { |m| m[:id] == id }

      legacy = legacy_alias_for("codex", id)
      return nil unless legacy
      return nil if added_entries_for("codex").any? { |entry| entry.model_id == id }

      legacy
    end

    # @return [Boolean] whether the model can only be driven via an interactive
    #   (OAuth) login rather than an API key. False for unknown models and for
    #   models whose entry omits the flag.
    def requires_oauth?(runtime, model)
      id = canonical_model_id(runtime, model).to_s
      entry = models_for(runtime).find { |m| m[:id] == id }
      entry ? !!entry[:requires_oauth] : false
    end

    # The reasoning-effort levels a session on this runtime and model may set in
    # `config["effort"]`. Empty when the model takes none — including every Codex
    # and Pi model, whose runtimes Zimmer does not pass an effort to, and any
    # model an operator added, whose levels Zimmer cannot know.
    #
    # @return [Array<String>]
    def effort_levels_for(runtime, model)
      built_in_entry(runtime, model)&.dig(:effort_levels) || []
    end

    # The level the runtime applies when a session names none, or nil when the
    # model takes no effort setting.
    #
    # @return [String, nil]
    def default_effort_for(runtime, model)
      built_in_entry(runtime, model)&.dig(:default_effort)
    end

    # Why `effort` cannot be used with this runtime and model, or nil when it
    # can. Blank `effort` is always fine: it means "the model's default".
    #
    # @return [String, nil]
    def effort_error(runtime, model, effort)
      return nil if effort.blank?

      key = resolve(runtime)
      levels = effort_levels_for(key, model)
      return nil if levels.include?(effort.to_s)

      if levels.empty?
        supported = MODELS.fetch(key, []).select { |m| m[:effort_levels].present? }.map { |m| m[:id] }
        if supported.empty?
          "effort is not supported on the #{key} runtime; omit it to use the model's default"
        else
          "model #{model.inspect} does not support an effort setting; omit effort, or pick one of: #{supported.join(', ')}"
        end
      else
        "effort #{effort.to_s.inspect} is not valid for model #{model.inspect}. Valid levels: #{levels.join(', ')} " \
          "(default: #{default_effort_for(key, model)})"
      end
    end

    # Every model with an effort setting, per runtime: the shape the new-session
    # form, get_configs and GET /api/v1/configs all describe.
    #
    # @return [Hash{String=>Hash{String=>Hash}}] runtime => model => { levels:, default: }
    def effort_options_by_runtime
      MODELS.to_h do |runtime, models|
        options = models.select { |m| m[:effort_levels].present? }
                        .to_h { |m| [ m[:id], { levels: m[:effort_levels], default: m[:default_effort] } ] }
        [ runtime, options ]
      end
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

    def legacy_model?(runtime, model)
      LEGACY_MODEL_ALIASES.fetch(resolve(runtime), {}).key?(model.to_s)
    end

    def legacy_alias_for(runtime, model)
      LEGACY_MODEL_ALIASES.fetch(resolve(runtime), {})[model.to_s]
    end

    def built_in_entry(runtime, model)
      MODELS.fetch(resolve(runtime), []).find { |m| m[:id] == model.to_s }
    end

    # An added model follows the built-in ones, and a deploy that promotes an added
    # id to built-in drops the now-redundant row rather than listing it twice. The
    # single implementation behind both #models_for and #models_by_runtime.
    def merge_added(built_in, built_in_ids, added_entries)
      built_in + added_entries.reject { |entry| built_in_ids.include?(entry.model_id) }.map do |entry|
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

    # Every added model, for the batch read above. Degrades the same way
    # #added_entries_for does, for the same reasons.
    def all_added_entries
      ModelCatalogEntry.order(:created_at, :id).to_a
    rescue ActiveRecord::StatementInvalid, ActiveRecord::ConnectionNotEstablished, ActiveRecord::NoDatabaseError => e
      Rails.logger.warn("[ModelCatalog] could not read added models: #{e.class}: #{e.message}")
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
