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
      # `args.key?` rather than `.present?`: an argument that was SENT but blank is
      # a caller that tried to name a session and got it wrong, and silently acting
      # on a different one is the worst available answer. find_session rejects it.
      return find_session(args["session_id"]) if args.key?("session_id") && !args["session_id"].nil?

      if context.self_session_id
        session = Session.find_by(id: context.self_session_id)
        if session
          @requester_defaulted = true
          return session
        end

        raise ToolError, "This MCP connection names session #{context.self_session_id} as the caller, " \
                         "but no such session exists. Pass an explicit session_id."
      end

      raise ToolError, "Missing required parameter: session_id. This MCP connection does not name a " \
                       "calling session, so the session to act on has to be given explicitly. " \
                       "Pass the id of the session this tool should act on."
    end

    # Whether the session this tool acted on came from the connection rather than
    # the arguments. A wake tool says so in its receipt: `session_id` is optional
    # now, so a caller that MEANT to sleep some other session and forgot the
    # argument has slept itself, and the only cheap way to make that recoverable
    # is to state it in the same turn. Nil until #requester_session has run.
    def requester_defaulted?
      @requester_defaulted == true
    end

    # Named in a wake tool's receipt whenever `session_id` was omitted, because
    # omitting it is now legal and the wrong session going to sleep is otherwise
    # silent. Both wake tools are in the `triggers` group as well as
    # `self_session`, so a caller holding a full-surface connection can genuinely
    # have meant a different session — and the sleep it just scheduled is on
    # itself. Saying so in the same turn is what makes that recoverable.
    def defaulted_requester_notice(session)
      return "" unless requester_defaulted?

      "\n\n⚠️ **No `session_id` was given, so this acted on the calling session (##{session.id})** — " \
        "the session this MCP connection belongs to. If you meant a different one, it is this session " \
        "that is now scheduled to sleep: pass `session_id` explicitly and cancel this trigger."
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

    # Permit when the connection allows ANY of `names` — for a root the app
    # resolves rather than the caller names, and whose resolution has aliases.
    # `allowed_agent_roots` is baked into a session's .mcp.json at spawn time, so
    # a session whose config was written under an alias is still carrying that
    # name on disk. Aliases denote one root at one location, so granting any of
    # them grants the rest; AgentRootsConfig::ROUTER_ROOT_NAMES is the only such
    # set, and a test pins its two entries to identical catalog coordinates.
    def enforce_any_allowed_root!(names)
      names = Array(names)
      raise ArgumentError, "enforce_any_allowed_root! needs at least one name" if names.empty?
      return unless context.restricted?
      return if (names & context.allowed_agent_roots).any?

      raise ToolError, "This MCP connection is restricted — agent root " \
                       "#{names.map(&:inspect).join(' or ')} is not permitted. " \
                       "Allowed agent roots: #{context.allowed_agent_roots.join(', ')}"
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
