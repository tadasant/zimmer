# frozen_string_literal: true

require "shellwords"

module Execution
  module Support
    # Builds secure Claude Code CLI commands with proper escaping and validation
    # Ensures all user input is properly sanitized before command execution
    class CommandBuilder
      class ValidationError < StandardError; end

      attr_reader :prompt, :working_dir, :mcp_config_path, :options

      # @param prompt [String] The prompt to send to Claude Code
      # @param working_dir [String] The working directory for execution
      # @param mcp_config_path [String, nil] Path to .mcp.json config file
      # @param options [Hash] Additional options for the command
      # @option options [String] :model The model to use (e.g., "claude-sonnet-4")
      # @option options [Integer] :timeout Command timeout in seconds
      # @option options [String] :api_key Anthropic API key
      def initialize(prompt:, working_dir:, mcp_config_path: nil, options: {})
        @prompt = prompt
        @working_dir = working_dir
        @mcp_config_path = mcp_config_path
        @options = options
        validate!
      end

      # Build the complete Claude Code CLI command
      # @return [String] The complete command string ready for execution
      def build
        command_parts = [ "claude" ]

        # Add working directory
        command_parts << "--working-directory" << Shellwords.escape(working_dir)

        # Add MCP config if provided
        if mcp_config_path
          command_parts << "--config" << Shellwords.escape(mcp_config_path)
        end

        # Add model if specified
        if options[:model]
          command_parts << "--model" << Shellwords.escape(options[:model])
        end

        # Add API key if specified (for CI/CD environments)
        if options[:api_key]
          command_parts << "--api-key" << Shellwords.escape(options[:api_key])
        end

        # Add the prompt (must be last)
        command_parts << "--prompt" << Shellwords.escape(prompt)

        command_parts.join(" ")
      end

      # Build command as an array (safer for Process.spawn)
      # @return [Array<String>] Command parts as array
      def build_array
        command_parts = [ "claude" ]

        command_parts << "--working-directory" << working_dir

        if mcp_config_path
          command_parts << "--config" << mcp_config_path
        end

        if options[:model]
          command_parts << "--model" << options[:model]
        end

        if options[:api_key]
          command_parts << "--api-key" << options[:api_key]
        end

        command_parts << "--prompt" << prompt

        command_parts
      end

      # Build environment variables for the command
      # @return [Hash<String, String>] Environment variables
      def build_env
        env = {}

        # Set timeout if specified
        if options[:timeout]
          env["CLAUDE_CODE_TIMEOUT"] = options[:timeout].to_s
        end

        # Add API key as environment variable (alternative to command line)
        if options[:api_key] && !options[:api_key_as_arg]
          env["ANTHROPIC_API_KEY"] = options[:api_key]
        end

        env
      end

      # Get execution options for spawn/system calls
      # @return [Hash] Options hash for Process.spawn
      def spawn_options
        opts = {}

        # Set working directory
        opts[:chdir] = working_dir if working_dir

        # Set timeout if specified
        if options[:timeout]
          opts[:timeout] = options[:timeout]
        end

        opts
      end

      private

      def validate!
        raise ValidationError, "prompt cannot be empty" if prompt.nil? || prompt.strip.empty?
        raise ValidationError, "working_dir cannot be empty" if working_dir.nil? || working_dir.strip.empty?
        raise ValidationError, "working_dir must be an absolute path" unless Pathname.new(working_dir).absolute?

        # Validate MCP config path if provided
        if mcp_config_path
          raise ValidationError, "mcp_config_path must be an absolute path" unless Pathname.new(mcp_config_path).absolute?
        end

        # Validate timeout if specified
        if options[:timeout]
          timeout = options[:timeout].to_i
          raise ValidationError, "timeout must be positive" if timeout <= 0
        end
      end
    end
  end
end
