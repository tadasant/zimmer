# frozen_string_literal: true

# RuntimeRegistry — the single lookup that maps a session's `agent_runtime`
# string to the bundle of classes that implement that runtime.
#
# Driving a coding-agent CLI involves several pluggable seams: spawning the CLI
# (RuntimeCliAdapter), classifying its exits for retry (retry strategy),
# reading/normalizing its transcript (TranscriptSource + TranscriptNormalizer),
# and contributing runtime-specific system-prompt guidance
# (RuntimePromptContribution). Today every one of those seams resolves to a
# Claude Code implementation. As the OpenAI Codex runtime lands
# (pulsemcp/pulsemcp#3766), the Codex bundle is registered here and callers
# transparently get the right classes for whichever runtime a session declares.
#
# The registry stores CLASSES, not instances — different call sites instantiate
# with different dependencies (file_system, process_manager, etc.). Roles that
# don't yet have a dedicated class (config preparer, auth provider, MCP
# credential writer) are left nil; the Phase-1 issues that introduce them
# (pulsemcp/pulsemcp#3773, pulsemcp/pulsemcp#3774) populate the corresponding
# bundle slots.
module RuntimeRegistry
  # The default runtime for sessions that don't specify one. Keeping this aligned
  # with the Session#agent_runtime column default preserves byte-identical
  # behavior for every existing session.
  DEFAULT_RUNTIME = "claude_code"

  # A runtime's collected implementations. Slots are nil until a class exists.
  #
  # `air_adapter_name` is the AIR CLI adapter id this runtime is prepared with
  # (`air prepare <adapter>`): claude → "claude", codex → "codex".
  # `config_post_processor_class` applies Zimmer-specific tweaks to the MCP config
  # AIR writes (server injection, env retargeting, secret resolution) in the
  # runtime's native format (`.mcp.json` for Claude, `.codex/config.toml` for
  # Codex).
  # `artifact_bridge_class` writes whatever the runtime needs in order to actually
  # RUN the session's AIR hooks and plugins after `air prepare` has been and gone —
  # a null object for the runtimes whose AIR adapter already does it, PiAirBridge
  # for Pi, whose adapter is skills-only.
  Bundle = Struct.new(
    :runtime,
    :air_adapter_name,
    :cli_adapter_class,
    :retry_strategy_class,
    :transcript_source_class,
    :transcript_normalizer_class,
    :mcp_status_detector_class,
    :prompt_contribution_class,
    :config_preparer_class,
    :config_post_processor_class,
    :artifact_bridge_class,
    :auth_provider_class,
    :mcp_credential_writer_class,
    keyword_init: true
  )

  CLAUDE_CODE_BUNDLE = Bundle.new(
    runtime: "claude_code",
    air_adapter_name: "claude",
    cli_adapter_class: ClaudeCliAdapter,
    retry_strategy_class: ClaudeRetryStrategy,
    transcript_source_class: ClaudeTranscriptSource,
    transcript_normalizer_class: ClaudeTranscriptNormalizer,
    # Claude Code derives per-server MCP status from its per-server log files.
    mcp_status_detector_class: McpLogPollerService,
    prompt_contribution_class: ClaudeRuntimePromptContribution,
    config_post_processor_class: ClaudeMcpConfigPostProcessor,
    # `air prepare claude` writes the hook table into .claude/settings.json and
    # materializes plugin content itself, so there is nothing left to bridge.
    artifact_bridge_class: NullRuntimeArtifactBridge,
    mcp_credential_writer_class: ClaudeMcpCredentialWriter,
    # Populated by forthcoming Phase-1 issues (pulsemcp/pulsemcp#3773 config
    # preparer, pulsemcp/pulsemcp#3774 auth provider). nil until those classes
    # exist.
    config_preparer_class: nil,
    auth_provider_class: nil
  ).freeze

  # OpenAI Codex runtime (pulsemcp/pulsemcp#3766). CodexRuntimeAdapter
  # (pulsemcp/pulsemcp#3777) implements the CLI seam, CodexRetryStrategy
  # classifies its exits, CodexConfigTomlPostProcessor (pulsemcp/pulsemcp#3778)
  # rewrites the `.codex/config.toml` AIR writes, the transcript source +
  # normalizer (pulsemcp/pulsemcp#3779) parse Codex rollouts, and
  # CodexMcpCredentialWriter (pulsemcp/pulsemcp#3782) is the MCP credential sink.
  # The remaining slots — prompt contribution (pulsemcp/pulsemcp#3783), config
  # preparer, auth provider (pulsemcp/pulsemcp#3780) — are populated by sibling
  # Phase-2 issues and stay nil until those classes land, exactly as the Claude
  # bundle leaves its pending slots nil. Registering the runtime here also makes
  # it selectable in the new-session form — AgentRootsConfig.available_runtimes
  # surfaces every registered runtime, decoupled from root default_runtime.
  CODEX_BUNDLE = Bundle.new(
    runtime: "codex",
    air_adapter_name: "codex",
    cli_adapter_class: CodexRuntimeAdapter,
    retry_strategy_class: CodexRetryStrategy,
    transcript_source_class: CodexTranscriptSource,
    transcript_normalizer_class: CodexTranscriptNormalizer,
    # Codex writes no per-server MCP log files; status is derived from rollout
    # `mcp__<server>__<tool>` function_call events (and best-effort stderr).
    mcp_status_detector_class: CodexMcpStatusDetector,
    prompt_contribution_class: nil,
    config_preparer_class: nil,
    config_post_processor_class: CodexConfigTomlPostProcessor,
    # Codex exposes no hook lifecycle for AIR to translate into, so there is
    # nothing for Zimmer to write after prepare either.
    artifact_bridge_class: NullRuntimeArtifactBridge,
    auth_provider_class: nil,
    mcp_credential_writer_class: CodexMcpCredentialWriter
  ).freeze

  # Pi coding agent runtime. Pi is the first runtime Zimmer supports that arrives
  # with NO MCP, hooks, or plugin support of its own — those are supplied by Pi
  # extensions (see PiExtensions), and `@pulsemcp/air-adapter-pi` is deliberately
  # skills-only. Two bundle slots follow directly from that:
  #
  #   * `config_post_processor_class` is PiMcpConfigPostProcessor, which SEEDS
  #     `.mcp.json` from Zimmer's catalog rather than merely adjusting a file AIR
  #     wrote — because for Pi, AIR writes none.
  #   * `mcp_status_detector_class` is NullMcpStatusDetector. Pi writes no
  #     per-server MCP log files (so the Claude log poller has nothing to read),
  #     and unlike Codex it records no `mcp__<server>__<tool>` calls to mine
  #     either: the pi-mcp-adapter extension routes every server through ONE
  #     `mcp` proxy tool, so a transcript shows `mcp` being called and never
  #     names the server behind it. There is no per-server signal to detect — but
  #     the slot gets a null object rather than nil, because
  #     TranscriptPollerService dereferences it unconditionally in its
  #     constructor, so a nil here is a NoMethodError on every poll of every Pi
  #     session.
  #   * `artifact_bridge_class` is PiAirBridge, which writes the AIR hooks and
  #     plugins config Pi's extensions read. `air prepare pi` writes none: the
  #     adapter ignores hook entries outright and honors a plugin only as
  #     composition sugar for its skills, so without the bridge a Pi session's
  #     selected hooks and plugins would exist in the database and nowhere else.
  #
  # `prompt_contribution_class` is populated here AND registered in
  # RuntimePromptContribution.for — the bundle slot is what the harness doc calls
  # dead weight today (nothing reads it), but leaving it nil while the class
  # exists is exactly the inconsistency zimmer#97 tracks, so Pi fills it.
  #
  # `auth_provider_class` follows the established convention and stays nil: auth
  # resolves through RuntimeAuthProvider.for, where PiAuthProvider is registered.
  # `config_preparer_class` is nil everywhere and nothing reads it.
  PI_BUNDLE = Bundle.new(
    runtime: "pi",
    air_adapter_name: "pi",
    cli_adapter_class: PiRuntimeAdapter,
    retry_strategy_class: PiRetryStrategy,
    transcript_source_class: PiTranscriptSource,
    transcript_normalizer_class: PiTranscriptNormalizer,
    mcp_status_detector_class: NullMcpStatusDetector,
    prompt_contribution_class: PiRuntimePromptContribution,
    config_preparer_class: nil,
    config_post_processor_class: PiMcpConfigPostProcessor,
    artifact_bridge_class: PiAirBridge,
    auth_provider_class: nil,
    mcp_credential_writer_class: nil
  ).freeze

  BUNDLES = {
    "claude_code" => CLAUDE_CODE_BUNDLE,
    "codex" => CODEX_BUNDLE,
    "pi" => PI_BUNDLE
  }.freeze

  # Human-readable labels for each runtime, surfaced in the UI (runtime selector,
  # session metadata badge). Runtimes without an explicit label fall back to their
  # raw identifier, so adding a runtime to BUNDLES without a label still renders.
  LABELS = {
    "claude_code" => "Claude Code",
    "codex" => "Codex",
    "pi" => "Pi"
  }.freeze

  module_function

  # Human-readable label for a runtime identifier.
  #
  # @param runtime [String, Symbol, nil] blank/nil resolves to the default runtime
  # @return [String] the display label, or the raw key when none is registered
  def label_for(runtime)
    key = runtime.presence&.to_s || DEFAULT_RUNTIME
    LABELS.fetch(key, key)
  end

  # Resolve the bundle for a runtime identifier.
  #
  # @param runtime [String, Symbol, nil] the session's agent_runtime. Blank/nil
  #   resolves to the default runtime so callers without an explicit runtime
  #   behave exactly as before.
  # @return [Bundle]
  # @raise [KeyError] if the runtime is not registered
  def for(runtime)
    key = runtime.presence&.to_s || DEFAULT_RUNTIME
    BUNDLES.fetch(key) do
      raise KeyError, "No runtime registered for #{key.inspect} (known: #{BUNDLES.keys.join(', ')})"
    end
  end

  # Resolve the CLI adapter CLASS for a session's runtime, letting an enabled Zimmer
  # Extension override the runtime bundle's default adapter.
  #
  # This is the single seam that governs which adapter drives a session. The core
  # asks Zimmer::ExtensionRegistry whether any enabled extension wants to substitute
  # an adapter for this runtime (the PTY transport does, for claude_code); if
  # none does, the runtime bundle's own cli_adapter_class is used unchanged —
  # preserving existing behavior byte-for-byte and keeping the core free of any
  # reference to a concrete extension. Both adapter call sites
  # (AgentSessionJob#cli_adapter_for and ProcessLifecycleManager#initialize) go
  # through here so the override lives in exactly one place.
  #
  # @param runtime [String, Symbol, nil] the session's agent_runtime
  # @return [Class] the CLI adapter class to instantiate
  def cli_adapter_class_for(runtime)
    bundle = self.for(runtime)
    Zimmer::ExtensionRegistry.cli_adapter_override_for(bundle.runtime) || bundle.cli_adapter_class
  end

  # Resolve a runtime identifier to its canonical registered key.
  #
  # Blank/nil resolves to the default runtime and an unregistered runtime raises,
  # so callers persisting a runtime get a normalized, validated value.
  #
  # @param runtime [String, Symbol, nil] the runtime to resolve
  # @return [String] the canonical runtime key
  # @raise [KeyError] if the runtime is not registered
  def resolve_key(runtime)
    self.for(runtime).runtime
  end

  # @return [Array<String>] the registered runtime identifiers
  def registered_runtimes
    BUNDLES.keys
  end

  # Every registered runtime's MCP credential writer class, deduplicated.
  #
  # An McpOauthCredential row is runtime-agnostic — one row per server config —
  # but each runtime keeps its own host-global copy of the tokens on disk. So
  # retiring a credential the provider revoked has to clear *every* runtime's
  # store, not just the one the failing session happened to run on: a copy left
  # behind in another runtime's store still carries its original future expiry,
  # and McpOauthRuntimeReconciler adopts it back into the DB on the next spawn
  # there. See McpOauthCredentialInjector#delete_runtime_credentials.
  #
  # @return [Array<Class>]
  def mcp_credential_writer_classes
    # `.compact`: a runtime whose slot is nil has no host-global credential store
    # to clear (Pi keeps MCP OAuth tokens inside the pi-mcp-adapter extension's
    # own state, which Zimmer does not write). The caller instantiates every class
    # this returns, so a nil left in the list would NoMethodError on the retire
    # path — which runs only while a credential is already failing, i.e. at the
    # worst possible moment. See McpOauthCredentialInjector#delete_runtime_credentials.
    BUNDLES.values.filter_map(&:mcp_credential_writer_class).uniq
  end
end
