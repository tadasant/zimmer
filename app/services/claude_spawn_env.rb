# frozen_string_literal: true

# ClaudeSpawnEnv — Claude-Code-specific environment preparation shared by every
# adapter that launches the `claude` binary.
#
# CliSpawnEnv contributes the two runtime-agnostic steps (load the per-clone
# `.env`, clear inherited DB/bundler vars). This module layers the Claude-Code
# specifics on top — the CLAUDE_CODE_* runtime flags, OAuth API-key injection,
# and MCP env wiring — so the `-p` adapter (ClaudeCliAdapter) and the
# interactive-PTY adapter (PtyClaudeCliAdapter) produce a byte-identical child
# environment. Without one shared seam, the two paths would drift and a session
# would behave differently depending on whether the pty_transport extension is on.
#
# The methods rely on the including class exposing `@file_system`, `@logger`,
# and `@ao_session_id`, which every Claude adapter already provides.
module ClaudeSpawnEnv
  include CliSpawnEnv

  # MCP server startup timeout in milliseconds. 3 minutes allows time for npm
  # package downloads on cold starts; once cached, servers connect in <5s.
  MCP_TIMEOUT_MS = 180_000

  private

  # Build the env hash for spawning a Claude Code process.
  #
  # Loads the per-clone .env, clears inherited DB/bundler vars, sets the
  # CLAUDE_CODE_* runtime flags, injects the OAuth API key when a custom
  # ANTHROPIC_BASE_URL is in play, and configures MCP env when the session uses
  # MCP servers. Returns the env hash ready to hand to process_manager.spawn.
  #
  # @param working_dir [String] the clone directory the child runs in
  # @param has_mcp [Boolean] whether the session has MCP servers configured
  # @param auto_compact_window [Integer] CLAUDE_CODE_AUTO_COMPACT_WINDOW value
  # @return [Hash] env vars for Process.spawn (nil values unset in the child)
  def build_claude_spawn_env(working_dir:, has_mcp:, auto_compact_window:)
    env_vars = load_env_file(working_dir)

    # Clear inherited environment variables that could interfere with the
    # spawned process — database vars (test isolation, #500) and Bundler vars
    # (gem path conflicts, #569). Setting them to nil unsets them in the child.
    env_vars = clear_inherited_env_vars(env_vars)

    # Zimmer's baseline is MCP tool search OFF — spawned sessions run with
    # ENABLE_TOOL_SEARCH=false to avoid unnecessary overhead during execution.
    # An enabled Zimmer Extension may flip this on (the mcp_tool_search extension
    # contributes ENABLE_TOOL_SEARCH=true via #spawn_env_contribution below). With
    # that extension removed, the baseline stands and tool search stays off.
    env_vars["ENABLE_TOOL_SEARCH"] = "false"

    # Disable in-process cron/scheduling tools (CronCreate, ScheduleWakeup, /loop).
    # These are session-scoped and unreliable in headless mode — Zimmer's trigger system
    # provides durable scheduling via ScheduleTriggerJob instead.
    env_vars["CLAUDE_CODE_DISABLE_CRON"] = "1"

    # Disable Claude Code's auto-memory feature. Zimmer sessions are session-scoped —
    # nothing durable should be persisted to ~/.claude/projects/<slug>/memory/ or
    # MEMORY.md. Anything worth keeping belongs in code, CLAUDE.md, SKILL.md, a
    # reference, or a PR/issue. settings.json/PreToolUse hooks are NOT a viable
    # alternative here because Zimmer sessions run with --dangerously-skip-permissions,
    # which bypasses both (see the comment on ClaudeCliAdapter::DISALLOWED_TOOLS).
    env_vars["CLAUDE_CODE_DISABLE_AUTO_MEMORY"] = "1"

    # Lower the auto-compact window so Claude Code compacts proactively, reducing
    # the chance of hitting hard context-length errors. Sessions that need more
    # context override this via auto_compact_window.
    env_vars["CLAUDE_CODE_AUTO_COMPACT_WINDOW"] = auto_compact_window.to_s

    inject_api_key_from_credentials(env_vars)
    configure_mcp_env(env_vars, working_dir) if has_mcp

    # Let enabled Zimmer Extensions contribute/override env vars (e.g. mcp_tool_search
    # flipping ENABLE_TOOL_SEARCH to "true"). Merged over the baseline above so an
    # extension can override an Zimmer default; with no extension enabled this is a
    # no-op and the child sees the baseline env unchanged.
    env_vars.merge!(Ao::ExtensionRegistry.spawn_env_contributions(runtime: "claude_code"))

    # Export the durable per-session scratch dir (AO_SESSION_SCRATCH_DIR) so
    # agents persist cross-step state on the durable volume instead of ephemeral /tmp.
    apply_session_scratch_dir(env_vars)

    env_vars
  end

  # Configure MCP-related environment variables for the spawned process.
  #
  # Sets a longer timeout for MCP server startup (package downloads on cold starts)
  # and isolates the npm cache per session to prevent corruption from concurrent
  # npx invocations (ENOTEMPTY / TAR_ENTRY_ERROR).
  def configure_mcp_env(env_vars, working_dir)
    env_vars["MCP_TIMEOUT"] = MCP_TIMEOUT_MS.to_s
    @logger.info "Setting MCP_TIMEOUT=#{MCP_TIMEOUT_MS}ms for MCP server startup"

    npm_cache_dir = File.join(working_dir, ".npm-cache")
    FileUtils.mkdir_p(npm_cache_dir)
    env_vars["NPM_CONFIG_CACHE"] = npm_cache_dir
    @logger.info "Isolating npm cache to #{npm_cache_dir}"

    configure_elicitation_env(env_vars)
  end

  # Set the session ID for MCP server elicitation callbacks.
  #
  # The @pulsemcp/mcp-elicitation library reads ELICITATION_SESSION_ID from
  # the environment and auto-includes it as com.pulsemcp/session-id in the
  # _meta of HTTP fallback POST requests. This lets the elicitation service
  # (Zimmer) associate each request with the correct session.
  #
  # Other elicitation env vars (ELICITATION_ENABLED, ELICITATION_REQUEST_URL,
  # ELICITATION_POLL_URL) are configured per-server in config/mcp.json.
  def configure_elicitation_env(env_vars)
    if @ao_session_id.present?
      env_vars["ELICITATION_SESSION_ID"] = @ao_session_id.to_s
      @logger.info "Set ELICITATION_SESSION_ID=#{@ao_session_id} for elicitation callbacks"
    end
  end

  # When ANTHROPIC_BASE_URL is set (e.g., pointing to a mock API for testing),
  # read the current OAuth access token from ~/.claude/.credentials.json and pass
  # it as ANTHROPIC_API_KEY to the Claude binary. This ensures the binary uses
  # the correct account identity after account rotation, where the credentials
  # file is updated but the parent process's env var would be stale.
  #
  # In production (no ANTHROPIC_BASE_URL), this is a no-op — the binary uses
  # its own OAuth flow to authenticate.
  def inject_api_key_from_credentials(env_vars)
    base_url = env_vars["ANTHROPIC_BASE_URL"] || ENV["ANTHROPIC_BASE_URL"]
    return unless base_url.present?

    home = ENV["HOME"] || Dir.home
    credentials_path = File.join(home, ".claude", ".credentials.json")
    return unless @file_system.exists?(credentials_path)

    data = JSON.parse(@file_system.read(credentials_path))
    token = data.dig("claudeAiOauth", "accessToken")
    if token.present?
      env_vars["ANTHROPIC_API_KEY"] = token
      @logger.info "Injected ANTHROPIC_API_KEY from credentials (custom ANTHROPIC_BASE_URL is set)"
    end
  rescue => e
    @logger.warn "Failed to inject API key from credentials: #{e.message}"
  end
end
