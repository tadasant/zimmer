# frozen_string_literal: true

module LiveConversations
  # The functions a live model can call, and what happens when it calls one.
  # Shared by both modes: a typed reply runs it inside its reply job, a voice call runs
  # it when the browser or phone relays a Realtime `function_call` to Rails.
  #
  # Three kinds of function:
  #
  # 1. **Zimmer** — `zimmer(tool, arguments)` and `describe_zimmer_tool(tool)`, a
  #    gateway onto Zimmer's own MCP surface, called in-process. This is how the
  #    live agent delegates: start a background session, check on it, follow up.
  #    A gateway rather than one function per tool because the default surface's
  #    definitions run to ~200 KB, which a realtime model cannot carry on every
  #    turn; the gateway's description lists each tool in one line instead.
  #    Present when the conversation has one of Zimmer's own catalog servers
  #    (`zimmer`, `zimmer-*`) enabled, scoped to the tool groups those name.
  # 2. **Catalog servers** — `list_mcp_servers`, `enable_mcp_server`,
  #    `disable_mcp_server`. Enabling a server persists it on the conversation
  #    and lists its tools once.
  # 3. **Direct tools** — every tool of every enabled non-Zimmer server, exposed
  #    as `<server>__<tool>` and executed through CatalogServer, so a capability
  #    the live agent keeps using costs one hop instead of a background session.
  # 4. **Its own settings** — `get_live_settings` and `update_live_settings`, so
  #    "talk faster" or "from now on, always …" said to the live agent becomes a
  #    change it makes itself (LiveSetting, through SettingsUpdate). Always
  #    present, whatever servers are enabled. A write is recorded in the settings
  #    history as this conversation's, and its tool turn shows on the page as a
  #    settings change; a voice client is handed a `session.update` for it.
  #
  # Every call is recorded as a `tool` turn on the conversation.
  class ToolBridge
    ZIMMER_TOOL = "zimmer"
    DESCRIBE_ZIMMER_TOOL = "describe_zimmer_tool"
    LIST_SERVERS = "list_mcp_servers"
    ENABLE_SERVER = "enable_mcp_server"
    DISABLE_SERVER = "disable_mcp_server"
    GET_SETTINGS = "get_live_settings"
    UPDATE_SETTINGS = "update_live_settings"
    DIRECT_SEPARATOR = "__"

    MAX_ENABLED_SERVERS = 8
    MAX_DIRECT_TOOLS = 80
    SUMMARY_LIMIT = 160
    FUNCTION_NAME_LIMIT = 64

    Function = Data.define(:name, :description, :parameters)
    # `session_changed`: the call changed a setting an open voice call can take
    # mid-call, so the client should send a fresh `session.update`.
    Result = Data.define(:turn, :output, :error, :tools_changed, :session_changed)

    class ToolFailure < StandardError; end

    def initialize(conversation)
      @conversation = conversation
    end

    # @return [Array<Function>]
    def functions
      list = []
      list.concat(zimmer_functions) if zimmer_tools.any?
      list.concat(server_functions)
      list.concat(settings_functions)
      list.concat(direct_functions.map(&:first))
      list
    end

    # Chat Completions' tool shape.
    def chat_tools
      functions.map { |f| { type: "function", function: { name: f.name, description: f.description, parameters: f.parameters } } }
    end

    # The Realtime API's tool shape (flat, no `function` wrapper).
    def realtime_tools
      functions.map { |f| { type: "function", name: f.name, description: f.description, parameters: f.parameters } }
    end

    # Run one call and record it.
    #
    # @param name [String] the function name the model called
    # @param arguments [String, Hash] the model's arguments (a JSON string as the wire carries it)
    # @param call_id [String] the model's call id, echoed back with the output
    # @return [Result]
    def execute(name, arguments, call_id:)
      args = nil
      @session_changed = false
      begin
        args = parse_arguments(arguments)
        output, error, tools_changed = dispatch(name.to_s, args)
      rescue ToolFailure => e
        output, error, tools_changed = e.message, true, false
      rescue StandardError => e
        # A tool that blows up is the model's problem to talk about, not the
        # conversation's to die of.
        ErrorReporter.report_exception(e, context: { source: "LiveConversations::ToolBridge", function: name.to_s, live_conversation_id: @conversation.id })
        output, error, tools_changed = "The tool failed: #{e.class}: #{e.message.to_s.truncate(300)}", true, false
      end

      turn = @conversation.turns.create!(
        role: "tool", tool_name: name.to_s, call_id: call_id.to_s,
        tool_arguments: args.is_a?(Hash) ? args : { "raw" => arguments.to_s.truncate(2_000) },
        tool_output: output.to_s, tool_error: error ? true : false
      )
      @conversation.touch_activity!
      Result.new(turn: turn, output: turn.model_output, error: turn.tool_error, tools_changed: tools_changed ? true : false,
                 session_changed: @session_changed && !turn.tool_error)
    end

    private

    def dispatch(name, args)
      case name
      when ZIMMER_TOOL then [ *call_zimmer(args), false ]
      when DESCRIBE_ZIMMER_TOOL then [ describe_zimmer(args), false, false ]
      when LIST_SERVERS then [ JSON.pretty_generate(server_listing), false, false ]
      when ENABLE_SERVER then [ enable_server(args), false, true ]
      when DISABLE_SERVER then [ disable_server(args), false, true ]
      when GET_SETTINGS then [ settings_listing, false, false ]
      when UPDATE_SETTINGS then [ update_settings(args), false, false ]
      else
        server_name, tool_name = direct_lookup[name]
        raise ToolFailure, "No function named #{name}. Call #{LIST_SERVERS} to see what is available." if server_name.nil?

        output, error = CatalogServer.find!(server_name).call_tool(tool_name, args)
        [ output, error, false ]
      end
    rescue CatalogServer::Unavailable => e
      raise ToolFailure, e.message
    end

    def parse_arguments(arguments)
      return arguments.to_unsafe_h.deep_stringify_keys if arguments.is_a?(ActionController::Parameters)
      return arguments.deep_stringify_keys if arguments.is_a?(Hash)
      return {} if arguments.blank?

      parsed = JSON.parse(arguments.to_s)
      raise ToolFailure, "Arguments must be a JSON object." unless parsed.is_a?(Hash)

      parsed
    rescue JSON::ParserError
      raise ToolFailure, "Arguments were not valid JSON."
    end

    # --- Zimmer's own surface -------------------------------------------------

    def zimmer_server_names
      @conversation.enabled_mcp_servers.select { |n| SelfSessionInjector.zimmer_server_name?(n) }
    end

    # The tool groups the enabled Zimmer servers name, read from their catalog
    # URLs. A Zimmer entry that names no groups is the full default surface. The
    # query is split by hand so a `${VAR}` host cannot make an entry unparseable
    # and so read as "everything".
    def zimmer_groups
      @zimmer_groups ||= zimmer_server_names.flat_map do |server_name|
        server = ServersConfig.find(server_name)
        next [] if server.nil?

        query = server.url.to_s.split("?", 2)[1].to_s
        groups = Rack::Utils.parse_query(query)["tool_groups"].to_s.split(",").map(&:strip).reject(&:empty?)
        groups.empty? ? Mcp::Registry::BASE_GROUPS : groups
      end.uniq
    end

    def mcp_context
      @mcp_context ||= Mcp::Context.new(
        tool_groups: zimmer_groups.join(","),
        base_url: AppUrl.base_url,
        caller_fingerprint: HealthActionCooldown.fingerprint("live_conversation:#{@conversation.id}")
      )
    end

    # Less the one tool that would let the live agent end or replace its own
    # conversation (`action_live_conversation`). Its group, `live_conversations`, is
    # opt-in and no shipped catalog entry names it, so this only bites when a
    # deployment's own `zimmer-*` entry does.
    def zimmer_tools
      return [] if zimmer_groups.empty?

      @zimmer_tools ||= mcp_context.tools.reject { |tool| tool == Mcp::Tools::ActionLiveConversation }
    end

    def zimmer_functions
      catalog = zimmer_tools.map { |tool| "- #{tool.tool_name}(#{required_args(tool).join(', ')}): #{summary(tool.description)}" }

      [
        Function.new(
          name: ZIMMER_TOOL,
          description: "Call a tool on Zimmer's MCP server. This is how you hand work to background agent " \
                       "sessions, check on them, and follow up. Arguments marked * are required; call " \
                       "#{DESCRIBE_ZIMMER_TOOL} first when you are unsure of a tool's arguments.\n#{catalog.join("\n")}",
          parameters: {
            type: "object",
            properties: {
              tool: { type: "string", enum: zimmer_tools.map(&:tool_name), description: "The Zimmer tool to call." },
              arguments: { type: "object", description: "The tool's arguments, as its schema describes them." }
            },
            required: %w[tool]
          }
        ),
        Function.new(
          name: DESCRIBE_ZIMMER_TOOL,
          description: "Return a Zimmer tool's full description and argument schema.",
          parameters: {
            type: "object",
            properties: { tool: { type: "string", enum: zimmer_tools.map(&:tool_name) } },
            required: %w[tool]
          }
        )
      ]
    end

    def find_zimmer_tool!(args)
      name = args["tool"].to_s
      tool = zimmer_tools.find { |t| t.tool_name == name }
      return tool if tool

      raise ToolFailure, "Zimmer has no tool named #{name.inspect} on this conversation's surface." if zimmer_tools.any?

      raise ToolFailure, "This conversation has no Zimmer server enabled. Call #{ENABLE_SERVER} with name \"zimmer\"."
    end

    def call_zimmer(args)
      tool = find_zimmer_tool!(args)
      arguments = args["arguments"]
      arguments = {} if arguments.nil?
      raise ToolFailure, "\"arguments\" must be an object." unless arguments.is_a?(Hash)

      # Through a real MCP server's `tools/call`, the path POST /mcp takes, so a
      # model's arguments meet the same required-argument and schema checks an
      # agent's do before any tool runs.
      response = mcp_server.handle(
        { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: tool.tool_name, arguments: arguments } }
      ) || {}
      if (error = response[:error])
        # A tool that raised comes back as a JSON-RPC error whose `data` says what
        # it raised; the SDK has already handed the exception to its reporter.
        raise ToolFailure, (error[:data].presence || error[:message]).to_s.presence || "Zimmer refused the call."
      end

      result = response[:result] || {}
      text = Array(result[:content]).map { |part| part[:text] || part["text"] }.compact.join("\n")
      [ text, result[:isError] ? true : false ]
    end

    def mcp_server
      @mcp_server ||= MCP::Server.new(name: Mcp::SERVER_NAME, version: Mcp::SERVER_VERSION, tools: zimmer_tools, server_context: mcp_context)
    end

    def describe_zimmer(args)
      tool = find_zimmer_tool!(args)
      "#{tool.description}\n\nArguments schema:\n#{JSON.pretty_generate(tool.input_schema.to_h)}"
    end

    def required_args(tool)
      Array(tool.input_schema.to_h[:required] || tool.input_schema.to_h["required"]).map { |arg| "#{arg}*" }
    end

    def summary(description)
      first = description.to_s.strip.split(/(?<=[.!?])\s|\n\n/, 2).first.to_s.squish
      first.truncate(SUMMARY_LIMIT)
    end

    # --- Catalog servers -------------------------------------------------------

    def server_functions
      [
        Function.new(
          name: LIST_SERVERS,
          description: "List the MCP servers in Zimmer's catalog, which ones this conversation has enabled, " \
                       "and whether each can be enabled.",
          parameters: { type: "object", properties: {} }
        ),
        Function.new(
          name: ENABLE_SERVER,
          description: "Enable a catalog MCP server on this conversation so its tools become functions you can " \
                       "call directly, without starting a background session. Do this when you find yourself " \
                       "delegating the same kind of call through Zimmer again and again.",
          parameters: { type: "object", properties: { name: { type: "string", description: "The catalog server's name." } }, required: %w[name] }
        ),
        Function.new(
          name: DISABLE_SERVER,
          description: "Disable a catalog MCP server on this conversation, removing its functions.",
          parameters: { type: "object", properties: { name: { type: "string" } }, required: %w[name] }
        )
      ]
    end

    def server_listing
      enabled = @conversation.enabled_mcp_servers
      ServersConfig.all.map do |server|
        catalog_server = CatalogServer.new(server)
        {
          name: server.name,
          title: server.title,
          description: server.description.to_s.truncate(200),
          enabled: enabled.include?(server.name),
          unavailable: catalog_server.unavailable_reason
        }.compact
      end
    end

    def enable_server(args)
      name = args["name"].to_s.strip
      raise ToolFailure, "Missing required parameter: name" if name.empty?

      enabled = @conversation.enabled_mcp_servers
      return "#{name} is already enabled." if enabled.include?(name)
      raise ToolFailure, "At most #{MAX_ENABLED_SERVERS} servers can be enabled at once; disable one first." if enabled.size >= MAX_ENABLED_SERVERS

      if SelfSessionInjector.zimmer_server_name?(name)
        raise ToolFailure, "No MCP server named #{name.inspect} in the catalog" if ServersConfig.find(name).nil?

        @conversation.with_lock { @conversation.update!(mcp_servers: (@conversation.enabled_mcp_servers + [ name ]).uniq) }
        reset!
        return "Enabled #{name}. Its tools are reachable through the #{ZIMMER_TOOL} function."
      end

      tools = CatalogServer.find!(name).list_tools
      # Under the row lock and re-read: a voice call runs tool calls side by side,
      # and two enables that both started from the old list must not drop one.
      @conversation.with_lock do
        @conversation.update!(
          mcp_servers: (@conversation.enabled_mcp_servers + [ name ]).uniq,
          mcp_tool_cache: @conversation.mcp_tool_cache.merge(name => tools.map(&:to_cache_entry))
        )
      end
      reset!

      names = direct_functions.filter_map { |function, (server, _)| function.name if server == name }
      "Enabled #{name}. You can now call these functions directly: #{names.join(', ')}."
    end

    def disable_server(args)
      name = args["name"].to_s.strip
      enabled = @conversation.enabled_mcp_servers
      return "#{name} was not enabled." unless enabled.include?(name)

      @conversation.with_lock do
        @conversation.update!(mcp_servers: @conversation.enabled_mcp_servers - [ name ], mcp_tool_cache: @conversation.mcp_tool_cache.except(name))
      end
      reset!
      "Disabled #{name}."
    end

    # --- Its own settings -------------------------------------------------------

    def settings_functions
      properties = LiveSetting::FIELDS.to_h do |field|
        schema = if field.numeric?
          { type: %w[number string], minimum: field.min, maximum: field.max }
        else
          { type: "string", enum: [ *LiveSetting.options_for(field).keys, "default" ] }
        end
        [ field.key.to_s, schema.merge(description: "#{field.label}. #{field.help}#{' A number, or "default".' if field.numeric?}") ]
      end

      [
        Function.new(
          name: GET_SETTINGS,
          description: "Read your own Live settings — models, voice, speaking speed, turn detection, output caps — " \
                       "with each one's choices or range, and the Live mode guidance.",
          parameters: { type: "object", properties: {} }
        ),
        Function.new(
          name: UPDATE_SETTINGS,
          description: "Change your own Live settings when the person asks. Pass only what changes; \"default\" puts a " \
                       "setting back. Speaking speed and turn detection change from your next reply; the models, " \
                       "voice and voice reasoning effort from the next call. `append_guidance` adds a standing " \
                       "instruction to the Live mode guidance; `guidance` replaces all of it — read it first. Every " \
                       "change is recorded and shown to the person; say out loud what you changed.",
          parameters: {
            type: "object",
            properties: properties.merge(
              "append_guidance" => { type: "string", description: "A standing instruction to add to the Live mode guidance, as its own line." },
              "guidance" => { type: "string", description: "The whole Live mode guidance, replacing what is there. Empty clears it." },
              "reset_to_defaults" => { type: "boolean", description: "Put every setting (not the guidance) back on its default." }
            )
          }
        )
      ]
    end

    def settings_listing = LiveSetting.current.describe

    def update_settings(args)
      reset = ActiveModel::Type::Boolean.new.cast(args["reset_to_defaults"]) ? true : false
      actor = SettingsUpdate::Actor.agent("live conversation ##{@conversation.id}", live_conversation: @conversation)
      result = SettingsUpdate.call(args.except("reset_to_defaults"), actor: actor, reset: reset)
      @session_changed = result.mid_call_changed?
      return "Nothing changed: those are already the settings." unless result.changed?

      later = result.keys.map(&:to_sym) & %i[voice_model voice_name voice_reasoning_effort]
      tail = later.any? ? "\n(#{later.map { |key| LiveSetting.field(key).label }.join(', ')}: from the next call.)" : ""
      "Changed:\n#{result.summary}#{tail}"
    rescue SettingsUpdate::Invalid => e
      raise ToolFailure, "Nothing changed. #{e.message}"
    end

    # --- Direct tools ----------------------------------------------------------

    # [[Function, [server_name, tool_name]], …], capped at MAX_DIRECT_TOOLS.
    def direct_functions
      @direct_functions ||= begin
        pairs = []
        @conversation.enabled_mcp_servers.each do |server_name|
          next if SelfSessionInjector.zimmer_server_name?(server_name)

          Array(@conversation.mcp_tool_cache[server_name]).each do |tool|
            function_name = direct_name(server_name, tool["name"])
            pairs << [
              Function.new(name: function_name, description: "[#{server_name}] #{tool['description']}", parameters: tool["input_schema"]),
              [ server_name, tool["name"] ]
            ]
          end
        end
        pairs.uniq { |function, _| function.name }.first(MAX_DIRECT_TOOLS)
      end
    end

    def direct_lookup
      @direct_lookup ||= direct_functions.to_h { |function, target| [ function.name, target ] }
    end

    def direct_name(server_name, tool_name)
      "#{sanitize(server_name)}#{DIRECT_SEPARATOR}#{sanitize(tool_name)}".first(FUNCTION_NAME_LIMIT)
    end

    def sanitize(value) = value.to_s.gsub(/[^a-zA-Z0-9_-]/, "_")

    def reset!
      @direct_functions = nil
      @direct_lookup = nil
      @zimmer_groups = nil
      @zimmer_tools = nil
      @mcp_context = nil
      @mcp_server = nil
    end
  end
end
