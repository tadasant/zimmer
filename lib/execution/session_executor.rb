# frozen_string_literal: true

module Execution
  # Main orchestrator for session execution
  # Coordinates provider lifecycle: setup -> execute -> cleanup
  # Logs results to session and updates status
  class SessionExecutor
    class ExecutionError < StandardError; end
    class ProviderNotFoundError < StandardError; end

    attr_reader :session, :context, :provider, :logger

    # @param session [Session] The session to execute
    # @param options [Hash] Additional execution options
    # @option options [String] :working_dir Override working directory
    # @option options [Integer] :timeout Execution timeout in seconds
    # @option options [String] :model Claude model to use
    def initialize(session, options: {})
      @session = session
      @context = Context.new(
        session: session,
        working_dir: options[:working_dir],
        options: options
      )
      @provider = create_provider
      @logger = Rails.logger
    end

    # Execute the full lifecycle: setup -> execute -> cleanup
    # @return [Execution::Result] Final execution result
    def execute!
      log_info("Starting execution for session #{session.id}")
      update_session_status(:running)

      begin
        # Setup phase
        setup_result = provider.setup
        log_execution_step("setup", setup_result)

        unless setup_result.success?
          update_session_status(:failed)
          return setup_result
        end

        # Execute phase
        execute_result = provider.execute
        log_execution_step("execute", execute_result)

        # Cleanup phase (always run, even if execute failed)
        cleanup_result = provider.cleanup
        log_execution_step("cleanup", cleanup_result)

        # Update final status based on execution result
        if execute_result.success?
          update_session_status(:archived)
        else
          update_session_status(:failed)
        end

        log_info("Execution completed for session #{session.id}")
        execute_result
      rescue StandardError => e
        log_error("Execution failed with exception: #{e.message}")
        log_error(e.backtrace.join("\n"))

        # Attempt cleanup even after error
        begin
          provider.cleanup
        rescue StandardError => cleanup_error
          log_error("Cleanup also failed: #{cleanup_error.message}")
        end

        update_session_status(:failed)
        Result.failure(
          error: "Execution failed: #{e.message}",
          metadata: {
            backtrace: e.backtrace,
            session_id: session.id
          },
          provider_type: provider.provider_type
        )
      end
    end

    # Setup only (useful for testing/debugging)
    # @return [Execution::Result]
    def setup
      log_info("Running setup for session #{session.id}")
      result = provider.setup
      log_execution_step("setup", result)
      result
    end

    # Execute only (assumes setup was already done)
    # @return [Execution::Result]
    def execute_only
      log_info("Running execute for session #{session.id}")
      result = provider.execute
      log_execution_step("execute", result)
      result
    end

    # Cleanup only
    # @return [Execution::Result]
    def cleanup
      log_info("Running cleanup for session #{session.id}")
      result = provider.cleanup
      log_execution_step("cleanup", result)
      result
    end

    # Get provider status
    # @return [Hash]
    def status
      provider.status
    end

    # Get execution info
    # @return [Hash]
    def info
      {
        session_id: session.id,
        provider_type: provider.provider_type,
        context: context.to_h,
        status: status
      }
    end

    private

    def create_provider
      provider_class = case context.provider_type
      when :local_filesystem
        Providers::LocalFilesystem
      when :remote_sandbox
        Providers::RemoteSandbox
      else
        raise ProviderNotFoundError, "Unknown provider type: #{context.provider_type}"
      end

      provider_class.new(context, logger: logger)
    end

    def log_execution_step(step, result)
      log_level = result.success? ? "info" : "error"

      # Create a log entry for this step with structured data as JSON
      log_data = {
        message: "[Execution] #{step.capitalize} #{result.success? ? 'succeeded' : 'failed'}",
        step: step,
        success: result.success?,
        provider_type: result.provider_type
      }

      # Add optional fields if present
      log_data[:output] = result.output if result.output.present?
      log_data[:error] = result.error if result.error.present?
      log_data[:metadata] = result.metadata if result.metadata.present?

      session.logs.create!(
        level: log_level,
        content: log_data.to_json
      )
    end

    def update_session_status(status)
      session.update!(status: status)
      log_info("Session #{session.id} status updated to #{status}")
    end

    def log_info(message)
      logger.info("[SessionExecutor] #{message}")
    end

    def log_error(message)
      logger.error("[SessionExecutor] #{message}")
    end

    def log_debug(message)
      logger.debug("[SessionExecutor] #{message}")
    end
  end
end
