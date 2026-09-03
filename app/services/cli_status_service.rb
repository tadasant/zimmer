# frozen_string_literal: true

require "open3"

# Service to check the installation and authentication status of CLI tools
#
# Checks for: gh (GitHub CLI), claude (Claude Code), codex (OpenAI Codex), fly (Fly.io CLI)
#
# Authentication strategies:
# - gh: either a GH_TOKEN in the environment — resolved from the ${VAR} chain by
#   GhTokenProvisioner, which is how staging authenticates — or an OAuth device
#   flow (`gh auth login`), whose token is stored in /home/rails/.config/gh
#   (volume-mounted from the host). A credential helper baked into Dockerfile.base
#   delegates git auth to `gh auth git-credential`, which honours both.
# - fly: Uses FLY_IO_API_TOKEN environment variable (no interactive login needed)
# - claude: Uses OAuth authentication (`claude auth login`, or the Authenticate
#   button on the accounts page). Its check is a Ruby callable rather than a
#   shell command — see the `claude` entry below for why.
# - codex: Uses OAuth authentication (requires manual `codex login` step);
#   credentials are stored in auth.json under CODEX_HOME (/home/rails/.codex)
#
# A tool may also declare `check_details`, a Ruby callable returning one line of
# operator-facing state that "installed + authenticated" does not cover. Only Pi
# uses it: its MCP, hooks and plugin support are separate npm packages, so a Pi
# that is installed and authenticated can still be missing all three, and
# `PiExtensions.status_summary` is the answer to that reachable without a shell
# on the box.
#
# An auth check must never be able to reach a billable path. `check_auth` is
# therefore either a Ruby callable returning a boolean, or a shell command whose
# argv is a REAL subcommand of the binary it invokes. That second condition is
# not pedantry: `claude`'s usage line is `claude [options] [command] [prompt]`,
# so any argv that is not a subcommand is a *prompt*, and the CLI answers it with
# a full agent turn. `cli_status_service_test.rb` asserts both properties.
#
# Performance optimization:
# - CLI status checks are performed by CliStatusRefreshJob (runs every 2 minutes)
# - Web endpoints read from cache and never block on shell commands
# - Cache TTL is 5 minutes to handle missed cron runs gracefully
class CliStatusService
  # Cache key for the full status report
  CACHE_KEY = "cli_status_full_report"

  # Cache TTL - slightly longer than cron interval to handle missed runs
  CACHE_TTL = 5.minutes

  CLI_TOOLS = {
    gh: {
      name: "GitHub CLI",
      check_installed: "which gh",
      check_auth: "gh auth status",
      check_version: "gh --version",
      auth_method: :oauth,
      install_instructions: <<~INSTRUCTIONS,
        # Pre-installed in Docker image
        # If missing, rebuild the Docker image
      INSTRUCTIONS
      auth_instructions: <<~INSTRUCTIONS
        # Two ways to authenticate gh. Preferred where the ${VAR} chain is wired:
        # put a GH_TOKEN in the Parameter Store and GhTokenProvisioner publishes
        # it into the environment on every boot and poll tick — no login, and it
        # survives a container rebuild. Otherwise `gh auth login` writes a gho_*
        # OAuth token to ~/.config/gh, volume-mounted from the host and shared
        # across web + worker containers.
        #
        # Option 1: Via Kamal (from your laptop)
        bin/kamal shell -d production

        # Option 2: Via SSH (on the server)
        ssh root@zimmer.example.com
        docker exec -it $(docker ps -q --filter name=zimmer-worker | head -1) bash

        # Then run the device-flow login (works across orgs, exempt from
        # classic-PAT bans, does not auto-expire):
        gh auth login
      INSTRUCTIONS
    },
    claude: {
      name: "Claude Code",
      check_installed: "which claude",
      # No `claude` invocation can answer this one, so it does not shell out.
      #
      # Two facts about the CLI, both verified against 2.1.258. First, `whoami`
      # is not a subcommand and `claude` takes a bare positional prompt, so that
      # argv is billed as an inference turn (#536) — which is what the
      # `check_auth` contract in the header exists to keep out. Second,
      # `claude auth status` IS a real subcommand and still cannot answer it: it
      # reports only credentials it finds in the ENVIRONMENT
      # (CLAUDE_CODE_OAUTH_TOKEN, ANTHROPIC_API_KEY), so against
      # ~/.claude/.credentials.json — the store the web and worker containers
      # authenticate from — it prints "Not logged in" and exits 1 with a
      # complete token pair sitting on disk.
      #
      # ClaudeCredentialHealth is the authority Zimmer already trusts for this
      # question — the same read the /health Agent Authentication card and
      # RefreshRuntimeAuthTokensJob use — and it follows the credential wherever
      # it lives: the shared file, or the current account's row under
      # session-scoped credentials.
      #
      # Like every other entry here, this reports whether a credential is
      # PRESENT and complete, not whether the vendor still honours it. A spent
      # pair reads as authenticated; the auth-outage park and the account pool's
      # own refresh sweep are what catch that. See limitations.md.
      check_auth: -> { ClaudeCredentialHealth.status.ok? },
      check_version: "claude --version",
      auth_method: :oauth,
      install_instructions: <<~INSTRUCTIONS,
        # Pre-installed in Docker image
        # If missing, rebuild the Docker image
      INSTRUCTIONS
      auth_instructions: <<~INSTRUCTIONS
        # Option 1: Via Kamal (from your laptop)
        bin/kamal shell -d production

        # Option 2: Via SSH (on the server)
        ssh root@zimmer.example.com
        docker exec -it $(docker ps -q --filter name=zimmer-worker | head -1) bash

        # Then run the OAuth login flow (the same argv ClaudeLoginDriver drives
        # for the Authenticate button on the accounts page):
        claude auth login
      INSTRUCTIONS
    },
    codex: {
      name: "OpenAI Codex",
      check_installed: "which codex",
      check_auth: "codex login status",
      check_version: "codex --version",
      auth_method: :oauth,
      install_instructions: <<~INSTRUCTIONS,
        # Pre-installed in Docker image (npm i -g @openai/codex)
        # If missing, rebuild the Docker image
      INSTRUCTIONS
      auth_instructions: <<~INSTRUCTIONS
        # Option 1: Via Kamal (from your laptop)
        bin/kamal shell -d production

        # Option 2: Via SSH (on the server)
        ssh root@zimmer.example.com
        docker exec -it $(docker ps -q --filter name=zimmer-worker | head -1) bash

        # Then run the OAuth login flow:
        codex login
      INSTRUCTIONS
    },
    pi: {
      name: "Pi Coding Agent",
      check_installed: "which pi",
      # Pi has no `login status` subcommand. `pi auth check` is the equivalent
      # question — it answers whether a provider credential resolves, from the
      # environment or from auth.json — and it requires an explicit --provider.
      # Verified against pi 0.84.4: prints `ready` and exits 0 when the key
      # resolves, `not_ready` and exits 1 when it does not. Anthropic is the
      # provider behind Pi's default model (see ModelCatalog).
      check_auth: "pi auth check --provider anthropic",
      check_version: "pi --version",
      # Pi resolves a provider credential per request from the session
      # environment rather than from a Zimmer-managed account pool, so this is an
      # env-var tool, not an OAuth one. See PiAuthProvider.
      auth_method: :env_var,
      env_var_name: "ANTHROPIC_API_KEY",
      # Pi is the one runtime whose "is it installed" answer is bigger than the
      # binary: it ships no MCP, hooks or plugins, so all three arrive as npm
      # packages the image installs separately (PiExtensions). A `pi` that is
      # present with its extensions missing looks completely healthy in every
      # other field here, and every session on it silently runs without them.
      # Reported as a line rather than a second tool because there is no separate
      # thing to authenticate.
      check_details: -> { PiExtensions.status_summary },
      install_instructions: <<~INSTRUCTIONS,
        # Pre-installed in Docker image (npm i -g @earendil-works/pi-coding-agent)
        # If missing, rebuild the Docker image
      INSTRUCTIONS
      auth_instructions: <<~INSTRUCTIONS
        # Pi authenticates from a provider API key in the session environment —
        # there is no interactive login step and no account pool to rotate.
        # Put the key in the Parameter Store so it reaches sessions through
        # SecretsLoader and survives a container rebuild:
        #
        #   ANTHROPIC_API_KEY  (for the anthropic/* models in ModelCatalog)
        #   OPENAI_API_KEY     (for the openai/* models)
        #
        # Pi extension status (MCP / hooks / plugins) is reported separately —
        # see PiExtensions.status_summary.
      INSTRUCTIONS
    },
    fly: {
      name: "Fly.io CLI",
      check_installed: "which fly || which flyctl",
      check_auth: "fly auth whoami || flyctl auth whoami",
      check_version: "fly version || flyctl version",
      auth_method: :env_var,
      env_var_name: "FLY_IO_API_TOKEN",
      install_instructions: <<~INSTRUCTIONS
        # Pre-installed in Docker image
        # If missing, rebuild the Docker image
      INSTRUCTIONS
    }
  }.freeze

  def initialize
    @results = {}
  end

  # Returns the full status report for all CLI tools
  def full_status_report
    CLI_TOOLS.each_key do |tool|
      @results[tool] = check_tool(tool)
    end

    {
      tools: @results,
      all_authenticated: all_authenticated?,
      unauthenticated_count: unauthenticated_count,
      generated_at: Time.current
    }
  end

  # Check if all tools are authenticated
  def all_authenticated?
    CLI_TOOLS.each_key do |tool|
      status = @results[tool] || check_tool(tool)
      return false unless status[:authenticated]
    end
    true
  end

  # Count of tools that are not authenticated
  def unauthenticated_count
    count = 0
    CLI_TOOLS.each_key do |tool|
      status = @results[tool] || check_tool(tool)
      count += 1 unless status[:authenticated]
    end
    count
  end

  # Get cached status report for web endpoints (never blocks on shell commands)
  #
  # Returns the cached report if available, otherwise returns a "loading" placeholder.
  # The actual CLI checks are performed by CliStatusRefreshJob running on a cron schedule.
  #
  # @return [Hash] The cached status report or a placeholder if cache is empty
  def self.cached_report
    Rails.cache.read(CACHE_KEY) || loading_placeholder
  end

  # Quick check just for badge status (reads from cache, never blocks)
  def self.unauthenticated_count
    cached_report[:unauthenticated_count]
  end

  # Clear the cached status (call after auth changes)
  def self.clear_cache
    Rails.cache.delete(CACHE_KEY)
  end

  # Placeholder returned when cache is empty (e.g., first load before cron runs)
  def self.loading_placeholder
    {
      tools: CLI_TOOLS.transform_values do |config|
        {
          name: config[:name],
          installed: nil, # Unknown - still loading
          authenticated: nil, # Unknown - still loading
          version: nil, # Unknown - still loading
          details: nil, # Unknown - still loading
          install_instructions: config[:install_instructions],
          auth_instructions: config[:auth_instructions],
          auth_method: config[:auth_method],
          env_var_name: config[:env_var_name],
          loading: true
        }
      end,
      all_authenticated: nil,
      unauthenticated_count: 0, # Show 0 while loading to avoid false alarms
      generated_at: nil,
      loading: true
    }
  end

  private

  def check_tool(tool)
    config = CLI_TOOLS[tool]

    installed = check_command(config[:check_installed])

    # Check authentication based on auth method
    authenticated = if config[:auth_method] == :env_var
      # For env var auth, check if the environment variable is set and non-empty
      ENV[config[:env_var_name]].present?
    else
      # For OAuth or other methods, run the auth check command
      installed && check_auth(config[:check_auth])
    end

    # Get version if installed and version command is configured
    version = installed && config[:check_version] ? get_version(config[:check_version]) : nil

    {
      name: config[:name],
      installed: installed,
      authenticated: authenticated,
      version: version,
      details: tool_details(config),
      install_instructions: config[:install_instructions],
      auth_instructions: config[:auth_instructions],
      auth_method: config[:auth_method],
      env_var_name: config[:env_var_name]
    }
  end

  # A tool's extra operator-facing line, or nil. Rescued rather than allowed to
  # escape: this report is what the CLIs page and `GET /api/v1/clis` render, and
  # a detail line that cannot be computed must not take the whole report down.
  def tool_details(config)
    config[:check_details]&.call
  rescue => e
    Rails.logger.warn "[CliStatusService] Could not compute details for #{config[:name]}: #{e.message}"
    nil
  end

  def check_command(command)
    system(command, out: File::NULL, err: File::NULL)
  end

  # A `check_auth` is either a Ruby callable returning a boolean — used when no
  # shell probe can answer the question without reaching a billable path — or a
  # shell command whose exit status is the answer.
  #
  # A callable that raises reports "not authenticated" rather than taking the
  # whole refresh down with it, which is the failure mode `system` already had.
  # It goes to Sentry as well as the log, because the visible symptom is a tile
  # stuck on "Not Authenticated" and nobody can reach a shell to grep for why.
  def check_auth(check)
    if check.respond_to?(:call)
      begin
        return !!check.call
      rescue => e
        Rails.logger.warn "[CliStatusService] Auth check raised: #{e.class}: #{e.message}"
        ErrorReporter.report_exception(e, context: { component: "CliStatusService" })
        return false
      end
    end

    result = system(check, out: File::NULL, err: File::NULL)
    result == true
  end

  # Extract version string from CLI tool output
  # Handles common formats like "2.1.87 (Claude Code)", "gh version 2.67.0", "0.3.47 fly"
  def get_version(command)
    # Split command into args for safe execution via Open3 (no shell interpolation)
    args = command.split(/\s*\|\|\s*/) # Handle "fly version || flyctl version" fallback patterns
    output = nil

    args.each do |cmd|
      parts = cmd.strip.split
      stdout, _stderr, status = Timeout.timeout(10) do
        Open3.capture3(*parts)
      end
      if SubprocessStatus.success?(status) && stdout.present?
        output = stdout.strip
        break
      end
    end

    return nil if output.blank?

    # Extract first version-like pattern (e.g., "2.1.87", "0.3.47")
    match = output.match(/(\d+\.\d+\.\d+)/)
    match ? match[1] : output.truncate(30)
  rescue Errno::ENOENT, Errno::EACCES, Timeout::Error
    nil
  end
end
