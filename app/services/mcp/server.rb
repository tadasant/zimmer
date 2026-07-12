# frozen_string_literal: true

module Mcp
  # Zimmer's native MCP server: the JSON-RPC 2.0 request dispatcher behind
  # POST /mcp.
  #
  # Zimmer speaks MCP itself rather than shelling out to a decoupled npm package
  # that calls back over the REST API. The protocol surface a tools-only server
  # needs is small — initialize, tools/list, tools/call, ping, plus ignoring the
  # client's notifications — so it is implemented here directly instead of taking
  # on an MCP SDK dependency: no streaming, no resources, no sampling, and the
  # per-request scoping (Mcp::Context) is Zimmer's own concept anyway.
  #
  # The transport is stateless streamable HTTP: every POST carries a complete
  # JSON-RPC message and gets a complete JSON response. No Mcp-Session-Id is
  # issued, so any Zimmer web worker can serve any request.
  class Server
    SERVER_NAME = "zimmer"
    # The app's release version, read from the repo's VERSION file at boot.
    SERVER_VERSION = (File.read(Rails.root.join("VERSION")).strip rescue "0.0.0")
    # Protocol revisions this server understands, newest first. The client's
    # requested version is echoed back when we support it; otherwise we answer
    # with our newest and let the client decide whether it can proceed.
    SUPPORTED_PROTOCOL_VERSIONS = %w[2025-06-18 2025-03-26 2024-11-05].freeze
    LATEST_PROTOCOL_VERSION = SUPPORTED_PROTOCOL_VERSIONS.first

    attr_reader :context

    def initialize(context:)
      @context = context
    end

    # Handle one parsed JSON-RPC message (request or notification).
    # @param message [Hash]
    # @return [Hash, nil] the JSON-RPC response, or nil for a notification
    def handle(message)
      unless message.is_a?(Hash) && message["jsonrpc"] == JsonRpc::VERSION
        return JsonRpc.error(message.is_a?(Hash) ? message["id"] : nil, JsonRpc::INVALID_REQUEST, "Invalid JSON-RPC request")
      end

      method = message["method"]
      id = message["id"]
      params = message["params"] || {}

      # Notifications (no id) get no response body.
      return nil if id.nil?

      case method
      when "initialize"       then JsonRpc.result(id, initialize_result(params))
      when "tools/list"       then JsonRpc.result(id, { "tools" => tool_definitions })
      when "tools/call"       then JsonRpc.result(id, call_tool(params))
      when "ping"             then JsonRpc.result(id, {})
      else
        JsonRpc.error(id, JsonRpc::METHOD_NOT_FOUND, "Method not found: #{method}")
      end
    rescue ProtocolError => e
      JsonRpc.error(message.is_a?(Hash) ? message["id"] : nil, e.code, e.message)
    rescue StandardError => e
      Rails.logger.error("[Mcp::Server] #{method} failed: #{e.class}: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}")
      ErrorReporter.report_exception(e, context: { mcp_method: method })
      JsonRpc.error(message.is_a?(Hash) ? message["id"] : nil, JsonRpc::INTERNAL_ERROR, "Internal error: #{e.message}")
    end

    def tool_definitions
      context.tools.map(&:definition)
    end

    private

    def initialize_result(params)
      requested = params["protocolVersion"]
      version = SUPPORTED_PROTOCOL_VERSIONS.include?(requested) ? requested : LATEST_PROTOCOL_VERSION

      {
        "protocolVersion" => version,
        "capabilities" => { "tools" => { "listChanged" => false } },
        "serverInfo" => {
          "name" => SERVER_NAME,
          "title" => "Zimmer",
          "version" => SERVER_VERSION
        },
        "instructions" => instructions
      }
    end

    def instructions
      "Zimmer's native MCP server. Tools operate on this Zimmer instance's sessions, " \
        "notifications, triggers, and system health. Enabled tool groups: #{context.tool_groups.join(', ')}."
    end

    def call_tool(params)
      name = params["name"]
      args = params["arguments"] || {}
      args = {} unless args.is_a?(Hash)

      klass = context.tools.find { |t| t.tool_name == name }
      raise ProtocolError.new("Unknown tool: #{name}", code: JsonRpc::INVALID_PARAMS) unless klass

      result = klass.new(context: context).call(args)
      tool_result(format_content(result))
    rescue ProtocolError
      # An unknown tool is a protocol-level error (the client asked for something
      # this connection never advertised), not a tool result the model should see.
      raise
    rescue ToolError => e
      tool_result(e.message, is_error: true)
    rescue ActiveRecord::RecordInvalid => e
      tool_result("Validation failed: #{e.record.errors.full_messages.join(', ')}", is_error: true)
    rescue ActiveRecord::RecordNotFound => e
      tool_result("Not found: #{e.message}", is_error: true)
    rescue AASM::InvalidTransition => e
      tool_result("Invalid state transition: #{e.message}", is_error: true)
    rescue StandardError => e
      Rails.logger.error("[Mcp::Server] tool #{name} raised #{e.class}: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}")
      ErrorReporter.report_exception(e, context: { mcp_tool: name })
      tool_result("Error executing #{name}: #{e.message}", is_error: true)
    end

    def format_content(result)
      case result
      when String then result
      when nil then ""
      else JSON.pretty_generate(result)
      end
    end

    def tool_result(text, is_error: false)
      { "content" => [ { "type" => "text", "text" => text } ], "isError" => is_error }
    end
  end
end
