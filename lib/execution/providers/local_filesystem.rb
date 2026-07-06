# frozen_string_literal: true

require "open3"
require "fileutils"
require "path_sanitizer"

module Execution
  module Providers
    # Local filesystem execution provider
    # Uses direct git clone for repository isolation
    # Executes Claude Code CLI in the clone
    class LocalFilesystem < Base
      attr_reader :clone_path, :mcp_config_path

      def provider_type
        :local_filesystem
      end

      # Set up the execution environment
      # - Clone repository directly from remote
      # - Generate .mcp.json config file
      def setup
        log_info("Setting up local filesystem execution for session #{context.session.id}")

        begin
          ensure_clones_directory
          create_clone
          generate_mcp_config

          log_info("Setup completed successfully")
          Result.success(
            output: "Setup completed",
            metadata: {
              clone_path: clone_path.to_s,
              mcp_config_path: mcp_config_path.to_s
            },
            provider_type: provider_type
          )
        rescue StandardError => e
          log_error("Setup failed: #{e.message}")
          Result.failure(
            error: "Setup failed: #{e.message}",
            metadata: { backtrace: e.backtrace },
            provider_type: provider_type
          )
        end
      end

      # Execute Claude Code CLI in the clone
      def execute
        log_info("Executing Claude Code for session #{context.session.id}")

        unless clone_exists?
          return Result.failure(
            error: "Clone not set up. Call setup first.",
            provider_type: provider_type
          )
        end

        begin
          output, error, status = run_claude_code_command

          if status.success?
            log_info("Execution completed successfully")
            Result.success(
              output: output,
              metadata: {
                exit_status: status.exitstatus,
                working_directory: clone_path.to_s
              },
              provider_type: provider_type
            )
          else
            log_error("Execution failed with exit status #{status.exitstatus}")
            Result.failure(
              error: error,
              output: output,
              exit_status: status.exitstatus,
              metadata: { working_directory: clone_path.to_s },
              provider_type: provider_type
            )
          end
        rescue StandardError => e
          log_error("Execution error: #{e.message}")
          Result.failure(
            error: "Execution error: #{e.message}",
            metadata: { backtrace: e.backtrace },
            provider_type: provider_type
          )
        end
      end

      # Clean up the clone and temporary files
      def cleanup
        log_info("Cleaning up execution environment for session #{context.session.id}")

        begin
          remove_clone if clone_exists?
          remove_mcp_config if mcp_config_exists?

          log_info("Cleanup completed successfully")
          Result.success(
            output: "Cleanup completed",
            provider_type: provider_type
          )
        rescue StandardError => e
          log_error("Cleanup failed: #{e.message}")
          Result.failure(
            error: "Cleanup failed: #{e.message}",
            metadata: { backtrace: e.backtrace },
            provider_type: provider_type
          )
        end
      end

      # Check if the environment is ready for execution
      def status
        {
          ready: clone_exists? && mcp_config_exists?,
          provider: provider_type,
          clone_path: clone_path&.to_s,
          mcp_config_path: mcp_config_path&.to_s
        }
      end

      # Get the transcript directory path for Claude Code
      # Claude Code stores transcripts in ~/.claude/projects/[sanitized-path]/
      # Uses clone_path which is the working directory for this provider
      # @return [String] The path to the transcript directory
      def transcript_directory
        return nil unless clone_path

        home_dir = File.expand_path("~")
        claude_projects_dir = File.join(home_dir, ".claude", "projects")
        # Note: For this provider, clone_path is the working directory
        sanitized_path = PathSanitizer.sanitize(clone_path)

        File.join(claude_projects_dir, sanitized_path)
      end

      private

      # Clone management

      def clones_dir
        # Resolve the clones base through the single source of truth (ClonesDirectory)
        # so this writer and the GC (StaleCloneCleanupJob / OrphanCloneFilesystemCleanupJob)
        # can never disagree about where clones live. Memoized per provider instance so a
        # session's clone path is stable for the duration of its execution.
        @clones_dir ||= Pathname.new(ClonesDirectory.base)
      end

      def ensure_clones_directory
        FileUtils.mkdir_p(clones_dir) unless Dir.exist?(clones_dir)
      end

      def clone_name
        # Use timestamp and random suffix for unique clone names
        @clone_name ||= begin
          timestamp = Time.now.to_i
          random_suffix = SecureRandom.hex(4)
          repo_name = context.repository_url.split("/").last.gsub(/\.git$/, "")
          "#{repo_name}-#{context.branch}-#{timestamp}-#{random_suffix}"
        end
      end

      def create_clone
        @clone_path = clones_dir.join(clone_name)

        if Dir.exist?(clone_path)
          log_debug("Clone already exists at #{clone_path}, removing old one")
          remove_clone
        end

        log_debug("Cloning repository from #{context.repository_url} (branch: #{context.branch})")

        # Use authenticated URL if GitHub PAT is available for private repos
        clone_url = authenticated_repository_url || context.repository_url

        # Clone directly from remote with specified branch
        stdout, stderr, status = Open3.capture3(
          "git", "clone",
          "--branch", context.branch,
          "--single-branch",
          clone_url,
          clone_path.to_s
        )

        unless status.success?
          raise "Failed to clone repository: #{stderr}"
        end

        log_debug("Successfully cloned repository to #{clone_path}")
      end

      def remove_clone
        return unless Dir.exist?(clone_path)

        log_debug("Removing clone at #{clone_path}")
        FileUtils.rm_rf(clone_path)
      end

      def clone_exists?
        clone_path && Dir.exist?(clone_path)
      end

      # MCP configuration

      def generate_mcp_config
        @mcp_config_path = clone_path.join(".mcp.json")

        air_service = AirPrepareService.new(
          session: context.session,
          working_directory: clone_path.to_s
        )
        air_service.prepare!

        log_debug("Generated MCP config at #{mcp_config_path}")
      end

      def remove_mcp_config
        File.delete(mcp_config_path) if mcp_config_exists?
      end

      def mcp_config_exists?
        mcp_config_path && File.exist?(mcp_config_path)
      end

      # Claude Code execution

      def run_claude_code_command
        command_builder = Support::CommandBuilder.new(
          prompt: context.prompt,
          working_dir: clone_path.to_s,
          mcp_config_path: mcp_config_path.to_s,
          options: build_command_options
        )

        log_debug("Executing command: #{command_builder.build}")

        # Use Open3.capture3 for better output handling
        stdout, stderr, status = Open3.capture3(
          command_builder.build_env,
          *command_builder.build_array,
          command_builder.spawn_options
        )

        [ stdout, stderr, status ]
      end

      def build_command_options
        options = {}

        # Add API key from environment if available
        options[:api_key] = ENV["ANTHROPIC_API_KEY"] if ENV.key?("ANTHROPIC_API_KEY")

        # Add timeout from context options
        options[:timeout] = context.options[:timeout] if context.options[:timeout]

        # Add model from context options
        options[:model] = context.options[:model] if context.options[:model]

        options
      end

      # Convert repository URL to authenticated URL if GitHub PAT is available
      # @return [String, nil] Authenticated URL or nil if no PAT available
      def authenticated_repository_url
        return nil unless github_pat.present?
        return nil unless context.repository_url.include?("github.com")

        # Parse the URL
        uri = URI.parse(context.repository_url)

        # Only modify HTTP(S) URLs, not SSH
        return nil unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)

        # Construct authenticated URL: https://TOKEN@github.com/owner/repo.git
        uri.userinfo = github_pat
        uri.to_s
      rescue URI::InvalidURIError => e
        log_error("Failed to parse repository URL: #{e.message}")
        nil
      end

      # Get GitHub Personal Access Token from credentials
      # @return [String, nil] GitHub PAT or nil if not configured
      def github_pat
        Rails.application.credentials.dig(:github, :personal_access_token)
      end
    end
  end
end
