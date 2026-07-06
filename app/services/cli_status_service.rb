# frozen_string_literal: true

require "open3"

# Service to check the installation and authentication status of CLI tools
#
# Checks for: gh (GitHub CLI), claude (Claude Code), codex (OpenAI Codex), fly (Fly.io CLI)
#
# Authentication strategies:
# - gh: OAuth device flow (`gh auth login`) — sole source of truth for git
#   credentials. The token is stored in /home/rails/.config/gh (volume-mounted
#   from the host) and a credential helper baked into Dockerfile.base
#   delegates git auth to `gh auth git-credential`. No GH_TOKEN env var.
# - fly: Uses FLY_IO_API_TOKEN environment variable (no interactive login needed)
# - claude: Uses OAuth authentication (requires manual `claude /login` step)
# - codex: Uses OAuth authentication (requires manual `codex login` step);
#   credentials are stored in auth.json under CODEX_HOME (/home/rails/.codex)
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
        # gh authentication is the sole source of truth for GitHub git auth
        # in production. There is no GH_TOKEN env var fallback — `gh auth login`
        # writes a gho_* OAuth token to ~/.config/gh, which is volume-mounted
        # from the host and shared across web + worker containers.
        #
        # Option 1: Via Kamal (from your laptop)
        bin/kamal shell -d production

        # Option 2: Via SSH (on the server)
        ssh root@zimmer.example.com
        docker exec -it $(docker ps -q --filter name=agent-orchestrator-worker | head -1) bash

        # Then run the device-flow login (works across orgs, exempt from
        # classic-PAT bans, does not auto-expire):
        gh auth login
      INSTRUCTIONS
    },
    claude: {
      name: "Claude Code",
      check_installed: "which claude",
      check_auth: "claude whoami",
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
        docker exec -it $(docker ps -q --filter name=agent-orchestrator-worker | head -1) bash

        # Then run the OAuth login flow:
        claude /login
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
        docker exec -it $(docker ps -q --filter name=agent-orchestrator-worker | head -1) bash

        # Then run the OAuth login flow:
        codex login
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
      install_instructions: config[:install_instructions],
      auth_instructions: config[:auth_instructions],
      auth_method: config[:auth_method],
      env_var_name: config[:env_var_name]
    }
  end

  def check_command(command)
    system(command, out: File::NULL, err: File::NULL)
  end

  def check_auth(command)
    # Run the auth check command and see if it succeeds
    result = system(command, out: File::NULL, err: File::NULL)
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
      if status.success? && stdout.present?
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
