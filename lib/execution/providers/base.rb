# frozen_string_literal: true

module Execution
  module Providers
    # Abstract base class for execution providers.
    # Defines the interface that all providers must implement.
    class Base
      attr_reader :context, :logger

      def initialize(context, logger: Rails.logger)
        @context = context
        @logger = logger
        validate_context!
      end

      # Set up the execution environment (clone repo, prepare workspace, etc.)
      # Must be implemented by subclasses
      # @return [Execution::Result]
      def setup
        raise NotImplementedError, "#{self.class} must implement #setup"
      end

      # Execute the agent with the given prompt
      # Must be implemented by subclasses
      # @return [Execution::Result]
      def execute
        raise NotImplementedError, "#{self.class} must implement #execute"
      end

      # Clean up the execution environment (remove workspace, etc.)
      # Must be implemented by subclasses
      # @return [Execution::Result]
      def cleanup
        raise NotImplementedError, "#{self.class} must implement #cleanup"
      end

      # Check the status of the execution environment
      # Optional to implement - defaults to success
      # @return [Hash] Status information
      def status
        { ready: true, provider: provider_type }
      end

      # Return information about this provider
      # @return [Hash]
      def provider_info
        {
          type: provider_type,
          context: context.to_h
        }
      end

      # Return the provider type symbol
      # Must be implemented by subclasses
      # @return [Symbol]
      def provider_type
        raise NotImplementedError, "#{self.class} must implement #provider_type"
      end

      protected

      # Log a message with the provider context
      def log_info(message)
        logger.info("[#{provider_type}] #{message}")
      end

      def log_error(message)
        logger.error("[#{provider_type}] #{message}")
      end

      def log_debug(message)
        logger.debug("[#{provider_type}] #{message}")
      end

      private

      def validate_context!
        raise ArgumentError, "context must be an Execution::Context" unless context.is_a?(Execution::Context)
      end
    end
  end
end
