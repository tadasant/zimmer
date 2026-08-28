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

    # The session that is CALLING — the one a self-management tool acts on when its
    # `session_id` argument is omitted.
    #
    # Nothing in an MCP request body identifies the caller, so the identity comes
    # from the connection: RuntimeConfigPostProcessor stamps `session_id` onto the
    # URL of the Zimmer entry it writes into a session's own runtime config, and
    # Mcp::Context carries it through. An explicit argument always wins — a session
    # is still free to schedule a wake for a different session.
    #
    # Falling back is what removes a whole round trip from every wake-up: without
    # it the agent's first call fails schema validation on a required argument it
    # cannot see the value of, and it has to look its own id up and call again.
    def requester_session(args)
      identifier = args["session_id"]
      return find_session(identifier) if identifier.present?

      if context.self_session_id
        session = Session.find_by(id: context.self_session_id)
        return session if session

        raise ToolError, "This MCP connection names session #{context.self_session_id} as the caller, " \
                         "but no such session exists. Pass an explicit session_id."
      end

      raise ToolError, "Missing required parameter: session_id. This MCP connection does not name a " \
                       "calling session, so the session to act on has to be given explicitly. " \
                       "Pass the id of the session this tool should act on."
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

    # Record the "uncle" lineage edge for a session-initiated queue/interrupt.
    #
    # The acting session is self-declared (`acting_session_id`), because nothing
    # about an MCP request identifies the caller: the API key is shared by the
    # whole fleet, and the endpoint's scoping is per-connection, not per-session.
    # Omitting it records nothing, which is the correct outcome for a human
    # driving this tool from an MCP client rather than an agent session.
    def record_uncle_edge(session, args, source)
      Sessions::RecordUncleEdge.call(
        junior: session,
        acting_session_id: args["acting_session_id"],
        source: source
      )
    end
  end
end
