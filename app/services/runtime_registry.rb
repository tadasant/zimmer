# frozen_string_literal: true

# RuntimeRegistry — the single lookup that maps a session's `agent_runtime`
# string to the bundle of classes that implement that runtime.
#
# Driving a coding-agent CLI involves several pluggable seams: spawning the CLI
# (RuntimeCliAdapter), classifying its exits for retry (retry strategy),
# reading/normalizing its transcript (TranscriptSource + TranscriptNormalizer),
# and contributing runtime-specific system-prompt guidance
# (RuntimePromptContribution). Today every one of those seams resolves to a
# Claude Code implementation. As the OpenAI Codex runtime lands (#3766), the
# Codex bundle is registered here and callers transparently get the right
# classes for whichever runtime a session declares.
#
# The registry stores CLASSES, not instances — different call sites instantiate
# with different dependencies (file_system, process_manager, etc.). Roles that
# don't yet have a dedicated class (config preparer, auth provider, MCP
# credential writer) are left nil; the Phase-1 issues that introduce them
# (#3773, #3774) populate the corresponding bundle slots.
module RuntimeRegistry
  # The default runtime for sessions that don't specify one. Keeping this aligned
  # with the Session#agent_runtime column default preserves byte-identical
  # behavior for every existing session.
  DEFAULT_RUNTIME = "claude_code"

  # A runtime's collected implementations. Slots are nil until a class exists.
  #
  # `air_adapter_name` is the AIR CLI adapter id this runtime is prepared with
  # (`air prepare <adapter>`): claude → "claude", codex → "codex".
  # `config_post_processor_class` applies AO-specific tweaks to the MCP config
  # AIR writes (server injection, env retargeting, secret/npx rewrites) in the
  # runtime's native format (`.mcp.json` for Claude, `.codex/config.toml` for
  # Codex).
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
    mcp_credential_writer_class: ClaudeMcpCredentialWriter,
    # Populated by forthcoming Phase-1 issues (#3773 config preparer, #3774 auth
    # provider). nil until those classes exist.
    config_preparer_class: nil,
    auth_provider_class: nil
  ).freeze

  # OpenAI Codex runtime (#3766). CodexRuntimeAdapter (#3777) implements the CLI
  # seam, CodexRetryStrategy classifies its exits, CodexConfigTomlPostProcessor
  # (#3778) rewrites the `.codex/config.toml` AIR writes, the transcript
  # source + normalizer (#3779) parse Codex rollouts, and CodexMcpCredentialWriter
  # (#3782) is the MCP credential sink. The remaining slots — prompt contribution
  # (#3783), config preparer, auth provider (#3780) — are populated by sibling
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
    auth_provider_class: nil,
    mcp_credential_writer_class: CodexMcpCredentialWriter
  ).freeze

  BUNDLES = {
    "claude_code" => CLAUDE_CODE_BUNDLE,
    "codex" => CODEX_BUNDLE
  }.freeze

  # Human-readable labels for each runtime, surfaced in the UI (runtime selector,
  # session metadata badge). Runtimes without an explicit label fall back to their
  # raw identifier, so adding a runtime to BUNDLES without a label still renders.
  LABELS = {
    "claude_code" => "Claude Code",
    "codex" => "Codex"
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

  # Resolve the CLI adapter CLASS for a session's runtime, letting an enabled AO
  # Extension override the runtime bundle's default adapter.
  #
  # This is the single seam that governs which adapter drives a session. The core
  # asks Ao::ExtensionRegistry whether any enabled extension wants to substitute
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
    Ao::ExtensionRegistry.cli_adapter_override_for(bundle.runtime) || bundle.cli_adapter_class
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
end
