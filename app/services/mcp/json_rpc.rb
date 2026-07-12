# frozen_string_literal: true

module Mcp
  # JSON-RPC 2.0 envelope helpers shared by the MCP server.
  module JsonRpc
    VERSION = "2.0"

    PARSE_ERROR = -32700
    INVALID_REQUEST = -32600
    METHOD_NOT_FOUND = -32601
    INVALID_PARAMS = -32602
    INTERNAL_ERROR = -32603

    module_function

    def result(id, payload)
      { "jsonrpc" => VERSION, "id" => id, "result" => payload }
    end

    def error(id, code, message, data: nil)
      err = { "code" => code, "message" => message }
      err["data"] = data if data
      { "jsonrpc" => VERSION, "id" => id, "error" => err }
    end
  end
end
