# frozen_string_literal: true

module Mcp
  # Adds the MCP Events extension to a connection's server: the capability, and
  # `events/list` / `events/poll` over SessionEvents.
  #
  # Offered exactly to a connection that can already read sessions (it carries
  # `get_session`), since an event says nothing that tool does not. A connection
  # fenced to some agent roots gets those roots' events and no others. A
  # connection that is not offered it declares no extension and answers
  # `events/*` with Method not found, as the SEP asks.
  module EventsExtension
    METHODS = %w[events/list events/poll].freeze
    # SEP-2243's routing header, which the extension requires on `events/poll`.
    HEADER_MISMATCH = -32_020

    module_function

    def offered?(context)
      context.tools.any? { |tool| tool <= Tools::GetSession }
    end

    def capabilities(server)
      server.capabilities.merge(
        extensions: (server.capabilities[:extensions] || {}).merge(McpEvents::EXTENSION_ID => {})
      )
    end

    # @param mcp_name [String, nil] the request's `Mcp-Name` header
    # @param on_header_mismatch [Proc] called when it does not name the event, so the
    #   controller can answer HTTP 400 as the transport's rules require
    def install(server, context, mcp_name: nil, on_header_mismatch: -> { })
      server.capabilities = capabilities(server)
      server.define_custom_method(method_name: "events/list") do |_params|
        { resultType: "complete", events: SessionEvents.descriptors }
      end
      server.define_custom_method(method_name: "events/poll") do |params|
        EventsExtension.poll(params || {}, context, mcp_name, on_header_mismatch)
      end
      server
    end

    def poll(params, context, mcp_name, on_header_mismatch)
      name = params[:name] || params["name"]
      unless mcp_name.to_s == name.to_s
        on_header_mismatch.call
        raise MCP::Server::RequestHandlerError.new(
          "The Mcp-Name header is missing or does not match params.name", params,
          error_type: :invalid_request, error_code: HEADER_MISMATCH, error_data: { header: "Mcp-Name" }
        )
      end

      SessionEvents::Feed.poll(params, readable: ->(root) { readable?(context, root) })
    rescue SessionEvents::Feed::Refused => e
      raise MCP::Server::RequestHandlerError.new(
        e.message, params, error_type: :invalid_params, error_code: McpEvents::ERROR_CODES.key(e.code), error_data: e.data
      )
    end

    def readable?(context, root)
      !context.restricted? || context.root_allowed?(root)
    end
  end
end
