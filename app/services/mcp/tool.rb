# frozen_string_literal: true

require "mcp"

module Mcp
  # Base class for a Zimmer MCP tool.
  #
  # Subclasses `MCP::Tool` from the official Ruby SDK, so the wire contract
  # (`tool_name`, `description`, `input_schema`, the `tools/list` payload, and
  # argument validation against the schema) is the SDK's. What this base adds is
  # Zimmer's calling convention:
  #
  #   * tools are instances, constructed with the connection's Mcp::Context, so
  #     scoping (allowed_agent_roots, base_url) is available to every call;
  #   * `#call(args)` receives string-keyed arguments and returns a String (sent
  #     as text content) or a Hash/Array (sent as pretty JSON);
  #   * raising Mcp::ToolError produces a tool result with `isError: true` and the
  #     message as text — something the calling model reads and can recover from,
  #     as opposed to a JSON-RPC protocol error, which it never sees.
  #
  # Tools talk to Zimmer's models and service objects directly — there is no HTTP
  # hop back into the REST API. Keep business logic in the services; a tool is an
  # argument validator, a caller, and a formatter.
  class Tool < MCP::Tool
    # A tool whose description embeds live state — `wake_me_up_later` interpolates
    # the current server time so the model can compute offsets — overrides this.
    # The SDK snapshots `description` at class-definition time, so anything dynamic
    # has to be re-rendered when the tool list is built.
    def self.rendered_description
      description
    end

    def self.to_h
      super.merge(description: rendered_description)
    end

    # The SDK calls tools as `Tool.call(**arguments, server_context:)` with
    # symbol keys. Zimmer's tools are instances that take string-keyed args, so
    # this is the single seam where the two conventions meet.
    def self.call(server_context: nil, **args)
      context = Context.unwrap(server_context)
      result = new(context: context).call(args.deep_stringify_keys)

      MCP::Tool::Response.new([ { type: "text", text: format_content(result) } ])
    rescue ToolError => e
      error_response(e.message)
    rescue ActiveRecord::RecordInvalid => e
      error_response("Validation failed: #{e.record.errors.full_messages.join(', ')}")
    rescue ActiveRecord::RecordNotFound => e
      error_response("Not found: #{e.message}")
    rescue AASM::InvalidTransition => e
      error_response("Invalid state transition: #{e.message}")
    end

    def self.format_content(result)
      case result
      when String then result
      when nil then ""
      else JSON.pretty_generate(result)
      end
    end

    def self.error_response(message)
      MCP::Tool::Response.new([ { type: "text", text: message } ], error: true)
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
