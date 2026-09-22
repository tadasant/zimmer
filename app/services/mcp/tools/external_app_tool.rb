# frozen_string_literal: true

module Mcp
  module Tools
    # The base for the tools a Zimmer plugin's key sees on `POST /mcp/external_app`.
    # They are never registered in Mcp::Registry, and #external_app refuses a
    # context that is not an Mcp::ExternalAppContext, so even a class reached some
    # other way cannot act for a plugin it was not authenticated as.
    class ExternalAppTool < Tool
      private

      def external_app
        unless context.is_a?(Mcp::ExternalAppContext)
          raise ToolError, "#{self.class.tool_name} is only available on a Zimmer plugin's connection (POST /mcp/external_app)."
        end

        context.external_app
      end
    end
  end
end
