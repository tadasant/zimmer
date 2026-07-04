# frozen_string_literal: true

module Execution
  module Providers
    # Remote sandbox execution provider (stub implementation)
    # TODO: Implement actual remote sandbox execution via API
    #
    # Future implementation will:
    # - Send repository_url, branch, prompt, mcp_servers to remote API
    # - Wait for execution to complete (with timeout)
    # - Stream logs back to session
    # - Return execution results
    # - Handle sandbox lifecycle (creation, execution, cleanup)
    class RemoteSandbox < Base
      def provider_type
        :remote_sandbox
      end

      def setup
        log_error("Remote sandbox provider not yet implemented")
        Result.failure(
          error: "Remote sandbox provider not yet implemented",
          metadata: not_implemented_metadata,
          provider_type: provider_type
        )
      end

      def execute
        log_error("Remote sandbox provider not yet implemented")
        Result.failure(
          error: "Remote sandbox provider not yet implemented",
          metadata: not_implemented_metadata,
          provider_type: provider_type
        )
      end

      def cleanup
        log_error("Remote sandbox provider not yet implemented")
        Result.failure(
          error: "Remote sandbox provider not yet implemented",
          metadata: not_implemented_metadata,
          provider_type: provider_type
        )
      end

      def status
        {
          ready: false,
          provider: provider_type,
          implemented: false,
          message: "Remote sandbox provider is not yet implemented"
        }
      end

      private

      def not_implemented_metadata
        {
          context: context.to_h,
          message: "The remote sandbox provider is a placeholder for future implementation.",
          next_steps: [
            "Implement remote sandbox API client",
            "Add authentication/authorization",
            "Implement sandbox lifecycle management",
            "Add streaming log support",
            "Add timeout and cancellation support"
          ]
        }
      end
    end
  end
end
