# frozen_string_literal: true

module OauthServer
  # An OAuth error with its RFC 6749 / 7591 / 8707 code (`invalid_request`,
  # `invalid_client_metadata`, `invalid_target`, …) and a description safe to
  # show the client.
  class Error < StandardError
    attr_reader :code

    def initialize(code, description)
      @code = code
      super(description)
    end

    def description = message

    def to_h = { error: code, error_description: description }
  end
end
