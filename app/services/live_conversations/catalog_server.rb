# frozen_string_literal: true

module LiveConversations
  # A catalog MCP server, spoken to by Rails on a live conversation's behalf —
  # the "skip the Zimmer hop" half of the tool bridge. The live model runs at
  # OpenAI and the client is a browser or a phone, none of which can run an
  # `npx` stdio server or hold its credentials, so the bridge lives here.
  #
  # - Remote servers (`streamable-http`, `sse`) go through McpApps::Client with
  #   the URL, headers and OAuth token McpServerEndpoint resolves.
  # - Stdio servers are spawned for the call and closed after it. Spawned with a
  #   scrubbed environment: the server's own catalog `env` (interpolated through
  #   the secrets chain) plus PATH/HOME, never the Rails process's environment and
  #   the database password, API keys and session secret in it.
  #
  # One process per call is the simple, stateless shape: a stdio server that keeps
  # state between calls (a browser) does not keep it across a live conversation's
  # calls. See docs/limitations.md.
  class CatalogServer
    class Unavailable < StandardError; end

    STDIO_TIMEOUT_SECONDS = 60
    INHERITED_ENV = %w[PATH HOME LANG LC_ALL TMPDIR USER].freeze

    DESCRIPTION_LIMIT = 600

    Tool = Data.define(:name, :description, :input_schema) do
      # What a conversation keeps of a tool between calls (mcp_tool_cache), so
      # building the function list never has to spawn the server.
      def to_cache_entry
        {
          "name" => name.to_s,
          "description" => description.to_s.truncate(DESCRIPTION_LIMIT),
          "input_schema" => input_schema.presence || { "type" => "object", "properties" => {} }
        }
      end
    end

    def self.find!(name)
      server = ServersConfig.find(name.to_s)
      raise Unavailable, "No MCP server named #{name.inspect} in the catalog" if server.nil?

      new(server)
    end

    attr_reader :server

    def initialize(server, interpolator: SecretsInterpolator.new)
      @server = server
      @interpolator = interpolator
    end

    def name = server.name

    # Why this server cannot be bridged at all, or nil when it can.
    def unavailable_reason
      return "the catalog marks it unavailable: #{server.unavailable_reason}" if server.declared_unavailable?
      return nil if server.remote? || server.stdio?

      "#{server.type.inspect} servers are not supported"
    end

    # @return [Array<Tool>]
    def list_tools
      with_connection do |connection|
        if connection.is_a?(McpApps::Client)
          connection.tools_list.map { |tool| Tool.new(tool["name"], tool["description"], tool["inputSchema"]) }
        else
          connection.tools.map { |tool| Tool.new(tool.name, tool.description, tool.input_schema) }
        end
      end
    end

    # @return [Array(String, Boolean)] the tool's text output and whether it is an error
    def call_tool(tool_name, arguments)
      result = with_connection do |connection|
        if connection.is_a?(McpApps::Client)
          connection.call_tool(tool_name, arguments)
        else
          connection.call_tool(name: tool_name, arguments: arguments)["result"]
        end
      end
      [ render_content(result), result.is_a?(Hash) && result["isError"] == true ]
    end

    private

    def with_connection
      reason = unavailable_reason
      raise Unavailable, "#{name}: #{reason}" if reason

      if server.remote?
        endpoint = McpServerEndpoint.new(server, interpolator: @interpolator)
        yield McpApps::Client.new(url: endpoint.url, headers: endpoint.headers)
      else
        transport = ScrubbedStdio.new(command: server.command, args: resolved_args, env: resolved_env,
          read_timeout: STDIO_TIMEOUT_SECONDS)
        client = MCP::Client.new(transport: transport)
        begin
          client.connect(client_info: { name: "zimmer-live", version: "1" })
          yield client
        ensure
          transport.close
        end
      end
    rescue McpServerEndpoint::UnresolvableError, SecretsInterpolator::MissingVariableError => e
      raise Unavailable, "#{name}: #{e.message}"
    rescue McpApps::Client::Error, McpApps::Client::ResponseTooLarge, MCP::Client::RequestHandlerError, MCP::Client::ServerError,
           MCP::Client::ValidationError, IOError, SystemCallError => e
      raise Unavailable, "#{name}: #{e.message.to_s.truncate(500)}"
    end

    def resolved_args = server.args.map { |arg| @interpolator.resolve(arg.to_s) }

    def resolved_env
      inherited = ENV.to_h.slice(*INHERITED_ENV)
      own = server.env.to_h.transform_values { |value| @interpolator.resolve(value.to_s) }
      inherited.merge(own)
    end

    def render_content(result)
      return result.to_s unless result.is_a?(Hash)

      parts = Array(result["content"]).map do |part|
        case part["type"]
        when "text" then part["text"].to_s
        when "resource" then part.dig("resource", "text").to_s.presence || "[resource #{part.dig('resource', 'uri')}]"
        else "[#{part['type']} content]"
        end
      end
      parts << JSON.generate(result["structuredContent"]) if parts.empty? && result["structuredContent"]
      parts.join("\n")
    end

    # MCP::Client::Stdio, minus the one thing a server Zimmer spawns must not get:
    # Ruby's spawn merges the given env into the parent's, so the stock transport
    # hands every child the whole Rails environment. `unsetenv_others` makes the
    # given env the child's entire environment.
    class ScrubbedStdio < MCP::Client::Stdio
      def start
        raise "MCP::Client::Stdio already started" if @started

        @stdin, @stdout, @stderr, @wait_thread = Open3.popen3(@env || {}, @command, *@args, unsetenv_others: true)
        @stdout.set_encoding("UTF-8")
        @stdin.set_encoding("UTF-8")
        @stderr_thread = Thread.new do
          loop { @stderr.readpartial(STDERR_READ_SIZE) }
        rescue IOError
          nil
        end
        @started = true
      rescue Errno::ENOENT, Errno::EACCES, Errno::ENOEXEC => e
        raise MCP::Client::RequestHandlerError.new("Failed to spawn server process: #{e.message}", {},
          error_type: :internal_error, original_error: e)
      end
    end
  end
end
