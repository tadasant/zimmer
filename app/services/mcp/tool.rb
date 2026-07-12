# frozen_string_literal: true

module Mcp
  # Base class for a native MCP tool.
  #
  # A tool declares its wire contract with the class-level DSL (`tool_name`,
  # `description`, `input_schema`) and implements `#call(args)`. Whatever `#call`
  # returns is serialized into MCP tool-result content: a String is sent as-is, a
  # Hash or Array is sent as pretty JSON. Raise Mcp::ToolError to return an error
  # result the calling model can read and recover from.
  #
  # Tools talk to Zimmer's models and service objects directly — there is no HTTP
  # hop back into the REST API. Keep business logic in the services; a tool is an
  # argument validator, a caller, and a formatter.
  class Tool
    class << self
      def tool_name(value = nil)
        @tool_name = value if value
        @tool_name
      end

      def description(value = nil)
        @description = value if value
        @description
      end

      def input_schema(value = nil)
        @input_schema = value if value
        @input_schema || { type: "object", properties: {} }
      end

      def definition
        {
          "name" => tool_name,
          "description" => description.to_s.strip,
          "inputSchema" => input_schema.deep_stringify_keys
        }
      end
    end

    attr_reader :context

    def initialize(context:)
      @context = context
    end

    def call(_args)
      raise NotImplementedError, "#{self.class} must implement #call"
    end

    private

    # --- Argument helpers -----------------------------------------------------

    def require_arg(args, key)
      value = args[key.to_s]
      raise ToolError, "Missing required parameter: #{key}" if value.nil? || (value.respond_to?(:empty?) && value.empty?)
      value
    end

    # Sessions are addressable by numeric id or slug, matching the REST API's
    # find_session behavior.
    def find_session(identifier)
      raise ToolError, "Missing required parameter: session_id" if identifier.blank?

      session = if identifier.to_s.match?(/\A\d+\z/)
        Session.find_by(id: identifier.to_i)
      else
        Session.find_by(slug: identifier.to_s)
      end

      raise ToolError, "Session not found: #{identifier}" unless session
      session
    end

    def enforce_allowed_root!(agent_root_name)
      return unless context.restricted?

      allowed = context.allowed_agent_roots
      if agent_root_name.blank?
        raise ToolError, "This MCP connection is restricted to specific agent roots — agent_root is required. " \
                         "Allowed agent roots: #{allowed.join(', ')}"
      end

      unless allowed.include?(agent_root_name)
        raise ToolError, "This MCP connection is restricted — agent root \"#{agent_root_name}\" is not permitted. " \
                         "Allowed agent roots: #{allowed.join(', ')}"
      end
    end

    def session_url(session)
      context.session_url(session)
    end
  end
end
