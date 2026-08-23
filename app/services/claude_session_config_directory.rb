# frozen_string_literal: true

# The per-session CLAUDE_CONFIG_DIR that makes the DB the sole owner of Claude's
# subscription credentials.
#
# Why this exists
# ---------------
# `~/.claude/.credentials.json` is host-global with three writers and no owner:
# Zimmer's account pool owns `claudeAiOauth`, ClaudeMcpCredentialWriter owns
# `mcpOAuth`, and the CLI rewrites both. On 2026-08-22 Zimmer's convergence write
# put a spent refresh token over the live one the CLI had rotated to; the CLI
# presented it, Anthropic answered `invalid_grant`, and the CLI blanked its own
# tokens. The credential then existed in neither store. See
# https://github.com/tadasant/zimmer/issues/618.
#
# Pointing each session at its own CLAUDE_CONFIG_DIR removes the shared file as a
# source of truth rather than guarding it. Combined with CLAUDE_CODE_OAUTH_TOKEN
# (which carries an access token and no refresh token), a session cannot rotate
# the subscription chain at all: measured on CLI 2.1.241, a session run this way
# writes a `.credentials.json` holding `mcpOAuth` and nothing else — there is no
# `claudeAiOauth` block on disk for anyone to move backwards.
#
# Durability + stability contract
# -------------------------------
#   * Durable: resolved as a sibling of ClonesDirectory.base, inside the same
#     `zimmer_data` volume that backs the clones, so a deploy or container
#     replacement does not destroy it — exactly like SessionScratchDirectory.
#   * Keyed on the session id, and STABLE for the session's whole life. This is
#     load-bearing, not tidiness: Claude Code keeps its conversation state under
#     CLAUDE_CONFIG_DIR, so `claude --resume <id>` only works when every
#     invocation of a session sees the same directory. A Zimmer session is a
#     long-lived record resumed by many short CLI processes; "fresh per session"
#     means fresh per Zimmer session, not per process.
#   * `projects/` is a SYMLINK to the shared ~/.claude/projects. CLAUDE_CONFIG_DIR
#     relocates the transcript tree as well as the credentials, and Zimmer reads
#     transcripts from the shared path in a dozen places (TranscriptPollerService,
#     AuthRecoveryService, ContextLengthRetryService, the MCP tools). Credentials
#     are what needs isolating; transcripts are not. The symlink keeps every
#     existing reader correct and untouched.
#
# Override the location with CLAUDE_SESSION_CONFIG_DIR. Point it outside the
# mounted volume and you must add a durable mount for it, or sessions lose their
# conversation state on the next deploy.
module ClaudeSessionConfigDirectory
  CONFIG_SUBDIR = "claude-config"

  # The directory name Claude Code keeps its transcript tree under, inside
  # CLAUDE_CONFIG_DIR.
  PROJECTS_DIRNAME = "projects"

  module_function

  # The base directory (parent of every per-session config dir).
  #
  # Resolved at call time (never memoized) so tests that stub HOME and ops that
  # set CLAUDE_SESSION_CONFIG_DIR are both honored without a process restart.
  #
  # @return [String]
  def base
    configured = ENV["CLAUDE_SESSION_CONFIG_DIR"].presence
    return File.expand_path(configured) if configured

    File.join(File.dirname(ClonesDirectory.base), CONFIG_SUBDIR)
  end

  # Whether THIS session should be run under its own CLAUDE_CONFIG_DIR.
  #
  # One predicate, consulted by both call sites, because they have to agree.
  # ClaudeSpawnEnv fails OPEN — with no current account or no stored token it
  # sets neither variable and the session reads the shared file — and MCP
  # credential injection runs BEFORE the spawn env is built. If the two answered
  # differently, injection would write the session's mcpOAuth map into a config
  # dir the CLI was never pointed at, and every OAuth MCP server in that session
  # would come up unauthenticated with nothing in the log to say why.
  #
  # Reads the setting and the pool rather than taking them as arguments, so a
  # caller cannot half-apply it by forgetting to thread one through.
  #
  # @param session_id [Integer, String, nil]
  # @return [Boolean]
  def active_for?(session_id)
    return false if session_id.blank?
    return false unless AppSetting.session_scoped_credentials_enabled?

    ClaudeAccount.current_account(ClaudeAuthProvider::RUNTIME)&.claude_access_token.present?
  rescue StandardError => e
    # Read on the session-spawn hot path. An unreadable settings row or DB blip
    # must degrade to the shared-file behaviour, not fail the spawn.
    Rails.logger.warn("[ClaudeSessionConfigDirectory] Could not resolve session-scoped credentials: #{e.message}")
    false
  end

  # Absolute path to a session's config dir (does not create it).
  #
  # @param session_id [Integer, String]
  # @return [String]
  # @raise [ArgumentError] if session_id is blank
  def path_for(session_id)
    raise ArgumentError, "session_id is required" if session_id.blank?

    File.join(base, session_id.to_s)
  end

  # The `.credentials.json` inside a session's config dir — the file the CLI
  # reads its `mcpOAuth` map from, and the only credential file a session under
  # this scheme ever sees.
  #
  # @param session_id [Integer, String]
  # @return [String]
  def credentials_path_for(session_id)
    File.join(path_for(session_id), ".credentials.json")
  end

  # Ensure a session's config dir exists — creating it and linking `projects/`
  # at the shared transcript tree — and return its absolute path.
  #
  # Idempotent, and safe against the two states a re-spawn can find: the symlink
  # already present (left alone), or a real `projects/` directory the CLI created
  # before this code shipped (left alone too, because replacing it would delete
  # transcripts). Only the absent case creates the link.
  #
  # @param session_id [Integer, String]
  # @return [String]
  def ensure_for(session_id)
    path = path_for(session_id)
    FileUtils.mkdir_p(path)
    link_projects!(path)
    path
  end

  # Remove a session's config dir if it exists. Called from the same clone GC
  # that reaps SessionScratchDirectory, so a session's Claude state is reclaimed
  # on the same schedule as its clone.
  #
  # Deletes the symlink itself, never the shared transcript tree behind it —
  # `FileUtils.rm_rf` does not follow symlinks, and the guard below makes that
  # explicit rather than relying on the reader knowing it.
  #
  # Defensive: never raises. Failing to reclaim a config dir must not break clone
  # cleanup.
  #
  # @param session_id [Integer, String]
  # @return [void]
  def cleanup_for(session_id)
    return if session_id.blank?

    path = path_for(session_id)
    return unless Dir.exist?(path)

    projects = File.join(path, PROJECTS_DIRNAME)
    File.delete(projects) if File.symlink?(projects)
    FileUtils.rm_rf(path)
    # A REAL `projects/` here — the pre-symlink layout — goes with the rest of
    # the directory, and that is correct rather than inconsistent with
    # #ensure_for: this runs when the session is being reaped, so its transcripts
    # are being reclaimed on purpose. #ensure_for declines to touch it because it
    # runs mid-life, when they are not.
  rescue => e
    Rails.logger.warn("[ClaudeSessionConfigDirectory] Failed to clean up config dir for session #{session_id}: #{e.message}")
  end

  # Point <config_dir>/projects at the shared transcript tree. Private by
  # convention — #ensure_for is the entry point.
  def link_projects!(path)
    link = File.join(path, PROJECTS_DIRNAME)
    return if File.symlink?(link) || File.exist?(link)

    shared = File.join(File.dirname(ClaudeAuthProvider::CREDENTIALS_JSON_PATH), PROJECTS_DIRNAME)
    FileUtils.mkdir_p(shared)
    File.symlink(shared, link)
  rescue Errno::EEXIST
    # Another spawn for the same session won the race; its link is ours.
    nil
  end
end
