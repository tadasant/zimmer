# frozen_string_literal: true

module Execution
  # Execution context value object containing all parameters needed for agent execution.
  # This is an immutable object passed between execution components.
  class Context
    attr_reader :session, :git_root, :branch, :mcp_servers, :prompt, :working_dir, :options

    def initialize(session:, git_root: nil, branch: nil, working_dir: nil, options: {})
      raise ArgumentError, "session cannot be nil" if session.nil?

      @session = session
      @git_root = git_root || session.git_root
      @branch = branch || session.branch || "main"
      @mcp_servers = session.mcp_servers || []
      @prompt = session.prompt
      @working_dir = working_dir
      @options = options.freeze

      validate!
      freeze
    end

    def to_h
      {
        session_id: session.id,
        git_root: git_root,
        branch: branch,
        mcp_servers: mcp_servers,
        prompt: prompt,
        working_dir: working_dir,
        options: options
      }
    end

    def provider_type
      session.execution_provider&.to_sym || :local_filesystem
    end

    # Alias for git_root to support LocalFilesystem provider
    alias repository_url git_root

    private

    def validate!
      raise ArgumentError, "prompt cannot be empty" if prompt.nil? || prompt.empty?
      raise ArgumentError, "git_root cannot be empty" if git_root.nil? || git_root.empty?
      raise ArgumentError, "branch cannot be empty" if branch.nil? || branch.empty?
    end
  end
end
