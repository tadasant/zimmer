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
# and `@zimmer_session_id`, which every Claude adapter already provides.
module ClaudeSpawnEnv
  include CliSpawnEnv

  # No Claude account is current, or the current one holds no access token, so
  # there is nothing to hand the child. Raised rather than swallowed: see
  # #apply_session_scoped_credentials.
  class MissingCredentialsError < StandardError; end

  # MCP server startup timeout in milliseconds. 3 minutes allows time for npm
  # package downloads on cold starts; once cached, servers connect in <5s.
  # Shared with Codex and Pi through McpStartupTimeout so the three runtimes
  # cannot drift into giving the same cold clone different amounts of room.
  #
  # The budget a session gets when none of its catalog entries declares one of its
  # own, and the floor under the value when one does: #configure_mcp_env spawns
  # with the longest `startup_timeout_sec` any of the session's servers declares,
  # or this, whichever is larger.
  MCP_TIMEOUT_MS = McpStartupTimeout::MILLISECONDS

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
    # spawned process — database vars (test isolation, pulsemcp/agents#500) and Bundler vars
    # (gem path conflicts, pulsemcp/agents#569). Setting them to nil unsets them in the child.
    env_vars = clear_inherited_env_vars(env_vars)

    # MCP tool search, governed by the global Settings toggle and ON by default:
    # the agent searches MCP tools on demand instead of loading every attached
    # server's tool schemas up front. With several servers attached that up-front
    # load is a large, unavoidable context cost at the start of every session.
    # Claude Code only — Codex ignores the variable, and CodexRuntimeAdapter
    # never runs this method.
    env_vars["ENABLE_TOOL_SEARCH"] = AppSetting.mcp_tool_search_enabled?.to_s

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

    # Issue #618's credential-ownership rearchitecture. This IS the session's
    # credential source — there is no shared ~/.claude/.credentials.json behind
    # it any more — so it raises rather than falling back when the pool has
    # nothing to hand over.
    apply_session_scoped_credentials(env_vars)

    inject_api_key_for_custom_base_url(env_vars)
    configure_mcp_env(env_vars, working_dir) if has_mcp

    # Let enabled Zimmer Extensions contribute/override env vars. Merged over the
    # baseline above so an extension can override a Zimmer default; with no
    # extension enabled this is a no-op and the child sees the baseline env
    # unchanged.
    apply_extension_env(env_vars, runtime: "claude_code")

    # Export the durable per-session scratch dir (AO_SESSION_SCRATCH_DIR) so
    # agents persist cross-step state on the durable volume instead of ephemeral /tmp.
    apply_session_scratch_dir(env_vars)

    # Cap the parallel test workers this session forks, so eight concurrent sessions
    # cannot each size a Rails suite off the whole droplet's processor count.
    apply_test_parallelism(env_vars)

    # Point the ssh-* MCP servers (and the plain ssh/git CLIs) at the operator SSH key.
    apply_operator_ssh_key(env_vars)

    # Tell MCP servers where to send approval requests (and who is asking).
    apply_elicitation_env(env_vars)

    env_vars
  end

  # Configure MCP-related environment variables for the spawned process.
  #
  # Sets a longer timeout for MCP server startup (package downloads on cold starts)
  # and isolates the npm cache per session to prevent corruption from concurrent
  # npx invocations (ENOTEMPTY / TAR_ENTRY_ERROR).
  #
  # Also repairs any npx bin shim in that cache whose target lost its execute bit,
  # which would otherwise fail the server's `exec` with EACCES on every retry and
  # orphan the session for the life of the clone (zimmer#467).
  def configure_mcp_env(env_vars, working_dir)
    timeout_ms = McpStartupTimeout.ceiling_milliseconds(configured_mcp_server_names(working_dir))
    env_vars["MCP_TIMEOUT"] = timeout_ms.to_s
    @logger.info "Setting MCP_TIMEOUT=#{timeout_ms}ms for MCP server startup"

    npm_cache_dir = File.join(working_dir, ".npm-cache")
    FileUtils.mkdir_p(npm_cache_dir)
    env_vars["NPM_CONFIG_CACHE"] = npm_cache_dir
    @logger.info "Isolating npm cache to #{npm_cache_dir}"

    NpxBinExecutableGuard.repair!(working_directory: working_dir, logger: @logger)
  end

  # The names of the MCP servers this session will actually launch, read out of
  # the `.mcp.json` the post-processor has already written — the same file Claude
  # itself is about to read, so the set cannot drift from what the runtime brings
  # up. A session whose config was never written (no MCP servers, or a resume
  # before prepare) yields none, and the default applies.
  #
  # Why this is needed at all: `MCP_TIMEOUT` is one value for the whole Claude
  # process, so the per-server budgets have to be collapsed into a single number
  # before the spawn, and the collapse is a max (McpStartupTimeout.ceiling_seconds)
  # so no server is given less room than its catalog entry asks for.
  #
  # Never fatal. An unreadable or malformed config costs the per-server budgets,
  # not the session: the ceiling falls back to the default.
  def configured_mcp_server_names(working_dir)
    # `<working_dir>/.mcp.json` rather than the `mcp_config_path` the adapter was
    # handed: `spawn_process` takes only the `has_mcp` boolean, and every caller
    # that computes that path builds this exact one (AgentSessionJob,
    # ProcessLifecycleManager). A caller that ever passed a different path would
    # get the default budget rather than a wrong one.
    path = File.join(working_dir.to_s, McpJsonConfigFormat::MCP_CONFIG_FILENAME)
    return [] unless @file_system.exists?(path)

    servers = JSON.parse(@file_system.read(path))[McpJsonConfigFormat::SERVERS_KEY]
    servers.is_a?(Hash) ? servers.keys : []
  rescue => e
    @logger.warn "Could not read MCP server names from #{path}: #{e.class}: #{e.message}. " \
      "Falling back to the default MCP startup timeout."
    []
  end

  # Point the session at its own CLAUDE_CONFIG_DIR and hand it an access token,
  # so it never holds — and therefore can never rotate — the subscription refresh
  # chain. The mechanism that makes "log in once, ever" true rather than
  # aspirational. See ClaudeSessionConfigDirectory and issue #618.
  #
  # Two variables, and both halves matter:
  #
  #   CLAUDE_CONFIG_DIR       moves the credential store out of the host-global
  #                           file every other session used to share. Measured on
  #                           CLI 2.1.241: a session run this way writes a
  #                           `.credentials.json` containing `mcpOAuth` and
  #                           nothing else — there is no `claudeAiOauth` block on
  #                           disk for anyone to move backwards over.
  #   CLAUDE_CODE_OAUTH_TOKEN carries an ACCESS token and no refresh token. Access
  #                           tokens live 8 hours; the longest `claude` process
  #                           ever observed on this deployment ran 1.27h (p99
  #                           0.09h over 42,971 runs), so a token fixed at spawn
  #                           needs no mid-process re-seeding.
  #
  # Fails CLOSED. This used to fall back to the shared credentials file when the
  # pool had nothing to offer, which was the right call while that file was still
  # a live rollback. It is not one now: nothing writes it, so falling back would
  # point the child at a fossil and every turn would come back "Not logged in ·
  # Please run /login" with nothing in the log to say why. Raising instead makes
  # ProcessLifecycleManager report a spawn failure, which fails the session with
  # `failure_reason: spawn_failed` and an .error line naming the cause — the same
  # visible ending a drained pool already produces, rather than a session that
  # runs and cannot think.
  #
  # Relies on the including adapter exposing `@zimmer_session_id`.
  #
  # @raise [MissingCredentialsError] when there is no session to key a config dir
  #   on, or no current account holding an access token
  def apply_session_scoped_credentials(env_vars)
    # ProcessLifecycleManager sets this from the session it was built for, so in
    # production it is always present. Saying so beats letting
    # ClaudeSessionConfigDirectory answer with a bare "session_id is required"
    # four frames down.
    if @zimmer_session_id.blank?
      raise MissingCredentialsError,
        "Cannot spawn Claude Code without a Zimmer session id: its credentials live in a per-session " \
        "CLAUDE_CONFIG_DIR keyed on that id"
    end

    account = ClaudeAccount.current_account(ClaudeAuthProvider::RUNTIME)
    token = account&.claude_access_token

    if token.blank?
      record_spawn_credentials(account: account)
      raise MissingCredentialsError,
        "No Claude account in the pool holds a usable access token#{account ? " (current: #{account.email})" : ""} — " \
        "authenticate one from /inference"
    end

    config_dir = ClaudeSessionConfigDirectory.ensure_for(@zimmer_session_id)
    env_vars["CLAUDE_CONFIG_DIR"] = config_dir
    env_vars["CLAUDE_CODE_OAUTH_TOKEN"] = token
    record_spawn_credentials(account: account)
    @logger.info "Set CLAUDE_CONFIG_DIR=#{config_dir} and CLAUDE_CODE_OAUTH_TOKEN (session-scoped credentials)"
    env_vars
  end

  def record_spawn_credentials(account:)
    AuthRecoveryCoordinator.record_spawn_credentials!(
      session_id: @zimmer_session_id,
      account: account
    )
  rescue => e
    # This is recovery observability, not a prerequisite for starting the child.
    # Keep the existing fail-open contract even if its DB lookup is unavailable.
    @logger.info "Could not record Claude spawn credentials: #{e.message}"
  end

  # When ANTHROPIC_BASE_URL is set (e.g. pointing at a mock API for testing),
  # pass the same access token the session runs on as ANTHROPIC_API_KEY, so a
  # mock that authenticates by header sees the identity the pool actually
  # selected rather than whatever the parent process was started with.
  #
  # Reads it back out of `env_vars` rather than from a file: that value is the
  # one truth about which credential this child gets, and
  # #apply_session_scoped_credentials has already raised if there is none. Its
  # predecessor read ~/.claude/.credentials.json, a file nothing writes any more.
  #
  # In production (no ANTHROPIC_BASE_URL) this is a no-op — the binary
  # authenticates from CLAUDE_CODE_OAUTH_TOKEN.
  def inject_api_key_for_custom_base_url(env_vars)
    base_url = env_vars["ANTHROPIC_BASE_URL"] || ENV["ANTHROPIC_BASE_URL"]
    return unless base_url.present?

    token = env_vars["CLAUDE_CODE_OAUTH_TOKEN"]
    return if token.blank?

    env_vars["ANTHROPIC_API_KEY"] = token
    @logger.info "Injected ANTHROPIC_API_KEY from the session's access token (custom ANTHROPIC_BASE_URL is set)"
  end
end
