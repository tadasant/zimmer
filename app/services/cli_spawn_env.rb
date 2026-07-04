# frozen_string_literal: true

# CliSpawnEnv — environment preparation shared by every runtime CLI adapter.
#
# Spawning a coding-agent CLI (claude, codex, ...) requires the same two
# runtime-agnostic env steps regardless of which binary is being launched:
#
#   1. Load the per-clone `.env` file (KEY=VALUE) so the agent sees the
#      session's configured environment.
#   2. Clear inherited database/bundler variables so the child process uses its
#      own configuration instead of AO's (issues #500 and #569).
#
# Both ClaudeCliAdapter and CodexRuntimeAdapter include this module. Adapters
# layer their own runtime-specific env vars (Claude's CLAUDE_CODE_* flags, MCP
# timeouts, etc.) on top of the hash these helpers return. The methods rely on
# the including class exposing `@file_system` (a FileSystemAdapter) and
# `@logger`, which every adapter already provides.
module CliSpawnEnv
  private

  # Load environment variables from a .env file if present in working_dir.
  #
  # Parses .env files in standard KEY=VALUE format:
  # - Supports comments (lines starting with #)
  # - Supports quoted values: KEY="value" or KEY='value'
  # - Supports empty values: KEY=
  # - Skips invalid lines gracefully
  #
  # Variable naming constraints:
  # - Must start with letter or underscore
  # - Can contain letters, numbers, and underscores (ASCII only)
  #
  # Limitations:
  # - Does not support multi-line values
  # - Does not expand variable references (e.g., $HOME)
  # - Does not support escape sequences in quoted strings
  #
  # @param working_dir [String] Directory to search for .env file
  # @return [Hash] Environment variables to pass to Process.spawn
  # @example
  #   # .env file contents:
  #   # API_KEY=secret123
  #   # DEBUG=true
  #   env_vars = load_env_file("/path/to/project")
  #   # => { "API_KEY" => "secret123", "DEBUG" => "true" }
  def load_env_file(working_dir)
    env_path = File.join(working_dir, ".env")

    # Return empty hash if .env doesn't exist
    return {} unless @file_system.exists?(env_path)

    # Check file size to prevent memory exhaustion from malicious/huge .env files
    max_size = 1.megabyte
    content = @file_system.read(env_path)
    if content.bytesize > max_size
      @logger.warn "Skipping .env file: exceeds maximum size of #{max_size} bytes (actual: #{content.bytesize} bytes)"
      return {}
    end

    @logger.info "Loading environment variables from .env file"

    env_vars = {}

    # Parse .env file line by line
    content.each_line do |line|
      # Skip empty lines and comments
      line = line.strip
      next if line.empty? || line.start_with?("#")

      # Parse KEY=VALUE format
      # Matches: VALID_VAR_NAME=value
      # Rejects: 123INVALID, -INVALID, INVALID-NAME
      if line =~ /\A([A-Za-z_][A-Za-z0-9_]*)=(.*)\z/
        key = Regexp.last_match(1)
        value = Regexp.last_match(2)

        # Remove surrounding quotes if present (matching quotes only)
        value = value.strip
        if (value.start_with?('"') && value.end_with?('"') && value.length >= 2) ||
           (value.start_with?("'") && value.end_with?("'") && value.length >= 2)
          value = value[1..-2]
        end

        env_vars[key] = value
      end
    end

    @logger.info "Loaded #{env_vars.size} environment variables from .env"
    env_vars
  rescue => e
    @logger.warn "Failed to load .env file: #{e.message}"
    {} # Return empty hash on error, don't fail the spawn
  end

  # Clear inherited environment variables that could interfere with the spawned process.
  #
  # When spawning agent CLI processes, child processes inherit the parent's
  # environment. This can cause issues:
  #
  # 1. Database isolation (issue #500): If the parent is a development Rails server,
  #    tests in the child would use the development database configuration.
  #
  # 2. Bundler isolation (issue #569): If the parent is running under Bundler,
  #    Ruby commands in the child would load gems from the parent's bundle path
  #    instead of the child's own bundle.
  #
  # By setting these variables to nil, Process.spawn will unset them in the child,
  # forcing the child to use its own configuration.
  #
  # Database variables cleared:
  # - DATABASE_URL: Complete database connection string (highest priority in Rails)
  # - DATABASE_HOST, DATABASE_PORT, DATABASE_NAME: Connection parameters
  # - DATABASE_USERNAME, DATABASE_PASSWORD: Credentials
  # - DATABASE_ADAPTER: Database type (postgresql)
  # - RAILS_ENV: Force child to determine its own environment
  #
  # Bundler variables cleared (explicit list, plus a BUNDLE*-prefix sweep below):
  # - BUNDLE_PATH: Where Bundler looks for gems
  # - BUNDLE_GEMFILE: Path to Gemfile
  # - BUNDLE_BIN_PATH: Path to bundle executable
  # - BUNDLE_APP_CONFIG: App-specific bundle config
  # - BUNDLE_DEPLOYMENT: Deployment mode flag
  # - BUNDLE_FROZEN: Frozen bundle flag
  # - BUNDLE_WITHOUT: Groups to exclude
  # - BUNDLE_WITH: Groups to include
  # - BUNDLER_SETUP: RubyGems auto-require hook that forces every child Ruby
  #   process to `require "bundler/setup"` at startup (modern Bundler exports
  #   this — and BUNDLER_VERSION / BUNDLER_ORIG_* — from `bundle exec`). If it
  #   leaks into a spawned agent, the FIRST Ruby process that chdir's into a
  #   project clone (e.g. the PTY driver under lib/pty_agent_driver.rb, which is
  #   itself Ruby and runs with chdir into the clone) auto-loads bundler/setup
  #   against that clone's Gemfile. When the clone's `bundle install` hasn't
  #   finished or has failed, that aborts the process with
  #   `Bundler::GemNotFound` BEFORE the agent CLI ever launches — turning a
  #   missing-gems condition into a fatal spawn failure. Decoupling the agent
  #   process from the project's bundle state is exactly why we clear this.
  # - BUNDLER_VERSION: Pins the Bundler version the auto-require resolves to;
  #   leaks alongside BUNDLER_SETUP and can force a version the clone lacks.
  # - GEM_HOME: Where gems are installed
  # - GEM_PATH: Where to find gems
  # - RUBYLIB: May contain bundler paths
  # - RUBYOPT: May contain -rbundler/setup
  # - RUBYGEMS_GEMDEPS: RubyGems' own gem-dependency auto-activation hook
  #
  # The explicit list documents the well-known offenders; the BUNDLE*-prefix
  # sweep over the parent ENV then catches the rest of the Bundler family
  # (BUNDLER_SETUP, BUNDLER_VERSION, BUNDLER_ORIG_*, and any future BUNDLE*/
  # BUNDLER* var) without having to enumerate every name. A value explicitly set
  # in the clone's .env always wins (we never overwrite an existing key).
  #
  # @param env_vars [Hash] Environment variables to pass to the child process
  # @return [Hash] Environment variables with inherited keys set to nil
  def clear_inherited_env_vars(env_vars)
    inherited_env_vars = %w[
      DATABASE_URL
      DATABASE_HOST
      DATABASE_PORT
      DATABASE_NAME
      DATABASE_USERNAME
      DATABASE_PASSWORD
      DATABASE_ADAPTER
      RAILS_ENV
      BUNDLE_PATH
      BUNDLE_GEMFILE
      BUNDLE_BIN_PATH
      BUNDLE_APP_CONFIG
      BUNDLE_DEPLOYMENT
      BUNDLE_FROZEN
      BUNDLE_WITHOUT
      BUNDLE_WITH
      BUNDLER_SETUP
      BUNDLER_VERSION
      GEM_HOME
      GEM_PATH
      RUBYLIB
      RUBYOPT
      RUBYGEMS_GEMDEPS
    ]

    # Set each inherited env var to nil to unset it in the child process
    # This allows the child to use its own configuration without inheritance
    inherited_env_vars.each do |var|
      # Only clear if not already explicitly set in the .env file
      # (i.e., if it's already nil or not present, set it to nil to unset)
      env_vars[var] = nil unless env_vars.key?(var)
    end

    # Sweep the parent ENV for the rest of the Bundler family. Modern Bundler
    # exports BUNDLER_SETUP (auto-require hook), BUNDLER_VERSION, and a set of
    # BUNDLER_ORIG_* preserved originals from `bundle exec`; any of these leaking
    # into a child Ruby process makes a missing/failed clone bundle fatal at
    # startup (see BUNDLER_SETUP note above). Enumerating the inherited ENV keys
    # catches the whole prefix family — including vars we don't name explicitly —
    # while still letting an explicit .env value win.
    ENV.each_key do |key|
      next if env_vars.key?(key)

      env_vars[key] = nil if key.start_with?("BUNDLE")
    end

    env_vars
  end

  # Export a durable per-session scratch directory to the spawned agent as
  # AO_SESSION_SCRATCH_DIR.
  #
  # Agents that need to persist cross-step state on disk should write here
  # instead of `/tmp`: in production `/tmp` is the container's ephemeral overlay
  # layer and is wiped on every container recreation (including a routine Kamal
  # deploy), whereas this directory lives on the durable clones named volume and
  # survives restarts/deploys. The directory is keyed on the stable session id,
  # so it is the same directory even if the session's clone is recreated.
  #
  # Best-effort: a failure to create the scratch dir must never break the spawn,
  # so on error we log and leave AO_SESSION_SCRATCH_DIR unset.
  #
  # Relies on the including adapter exposing `@ao_session_id`.
  #
  # @param env_vars [Hash] Environment variables to pass to the child process
  # @return [Hash] env_vars with AO_SESSION_SCRATCH_DIR set when available
  def apply_session_scratch_dir(env_vars)
    return env_vars if @ao_session_id.blank?

    path = SessionScratchDirectory.ensure_for(@ao_session_id)
    env_vars["AO_SESSION_SCRATCH_DIR"] = path
    @logger.info "Set AO_SESSION_SCRATCH_DIR=#{path} (durable per-session scratch)"
    env_vars
  rescue => e
    @logger.warn "Failed to set up session scratch dir: #{e.message}"
    env_vars
  end
end
