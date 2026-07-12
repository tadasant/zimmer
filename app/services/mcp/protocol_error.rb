# frozen_string_literal: true

module Mcp
  # Raised for JSON-RPC-level problems (unknown method, unknown tool, malformed
  # request). These become JSON-RPC error responses rather than tool results.
  class ProtocolError < StandardError
    attr_reader :code

    def initialize(message, code: JsonRpc::INVALID_REQUEST)
      super(message)
      @code = code
    end
  end
end
