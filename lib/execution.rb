# frozen_string_literal: true

# Execution layer for agent session management
# Provides abstraction over local filesystem and remote sandbox execution
#
# Usage:
#   session = Session.create!(prompt: "...", repository_url: "...", ...)
#   executor = Execution::SessionExecutor.new(session)
#   result = executor.execute!
#
module Execution
  class Error < StandardError; end

  # Convenience method to execute a session
  # @param session [Session] The session to execute
  # @param options [Hash] Execution options
  # @return [Execution::Result]
  def self.execute(session, options: {})
    executor = SessionExecutor.new(session, options: options)
    executor.execute!
  end

  # Get execution status for a session
  # @param session [Session] The session to check
  # @return [Hash] Status information
  def self.status(session, options: {})
    executor = SessionExecutor.new(session, options: options)
    executor.status
  end
end

# Require all execution components
require_relative "execution/context"
require_relative "execution/result"
require_relative "execution/providers/base"
require_relative "execution/providers/local_filesystem"
require_relative "execution/providers/remote_sandbox"
require_relative "execution/support/command_builder"
require_relative "execution/session_executor"
