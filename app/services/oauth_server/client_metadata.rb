# frozen_string_literal: true

module OauthServer
  # The client-metadata rules both registration paths share: a DCR request body
  # (RFC 7591) and a Client ID Metadata Document are the same JSON shape, and are
  # held to the same rules.
  #
  # - Public clients only. `token_endpoint_auth_method` must be absent or `none`,
  #   and a document carrying a `client_secret` is refused.
  # - `redirect_uris` is required. Each must be absolute `https`, or `http` on a
  #   loopback host (a native client listening on this computer). No fragment, no
  #   userinfo, no custom schemes.
  # - `grant_types` / `response_types`, when present, must INCLUDE
  #   `authorization_code` / `code`. Anything else they list (Claude.ai's
  #   documents list the JWT-bearer grant; VS Code's, the device-code grant) is
  #   narrowed away rather than refused, which is what RFC 7591 §2 asks of a
  #   server that does not support a requested value.
  module ClientMetadata
    MAX_REDIRECT_URIS = 32
    MAX_REDIRECT_URI_LENGTH = 2048
    MAX_CLIENT_NAME_LENGTH = 128
    GRANT_TYPES = %w[authorization_code refresh_token].freeze
    LOOPBACK_HOSTS = %w[localhost 127.0.0.1 [::1] ::1].freeze

    Parsed = Data.define(:client_name, :client_uri, :redirect_uris, :grant_types)

    module_function

    # @param doc [Hash] parsed JSON
    # @param error_code [String] the code to raise with (`invalid_client_metadata` for DCR)
    # @return [Parsed]
    def parse!(doc, error_code: "invalid_client_metadata")
      raise Error.new(error_code, "client metadata must be a JSON object") unless doc.is_a?(Hash)

      if doc.key?("client_secret") || doc.key?("client_secret_expires_at")
        raise Error.new(error_code, "only public clients are supported; client metadata must not carry a client_secret")
      end

      auth_method = doc["token_endpoint_auth_method"]
      unless auth_method.nil? || auth_method == "none"
        raise Error.new(error_code, "token_endpoint_auth_method must be \"none\": only public clients using PKCE are supported")
      end

      Parsed.new(
        client_name: client_name(doc["client_name"]),
        client_uri: doc["client_uri"].is_a?(String) ? doc["client_uri"].first(MAX_REDIRECT_URI_LENGTH) : nil,
        redirect_uris: redirect_uris!(doc["redirect_uris"]),
        grant_types: grant_types!(doc, error_code)
      )
    end

    def redirect_uris!(value)
      unless value.is_a?(Array) && value.any? && value.all?(String)
        raise Error.new("invalid_redirect_uri", "redirect_uris must be a non-empty array of strings")
      end
      if value.size > MAX_REDIRECT_URIS
        raise Error.new("invalid_redirect_uri", "at most #{MAX_REDIRECT_URIS} redirect_uris are accepted")
      end

      value.uniq.each do |uri|
        problem = redirect_uri_problem(uri)
        raise Error.new("invalid_redirect_uri", "redirect_uri #{uri.inspect} #{problem}") if problem
      end
    end

    # nil when acceptable, otherwise why not.
    def redirect_uri_problem(uri)
      return "is too long" if uri.length > MAX_REDIRECT_URI_LENGTH

      parsed = URI.parse(uri)
      return "must be an absolute URI" unless parsed.absolute? && parsed.host.present?
      return "must not carry a fragment" if parsed.fragment
      return "must not carry userinfo" if parsed.userinfo

      case parsed.scheme
      when "https" then nil
      when "http" then loopback_host?(parsed.host) ? nil : "must use https (http is accepted only on a loopback host)"
      else "must use https"
      end
    rescue URI::InvalidURIError
      "is not a valid URI"
    end

    def loopback_host?(host)
      LOOPBACK_HOSTS.include?(host.to_s.downcase)
    end

    # A redirect to a program on the human's own computer: worth a line on the
    # consent screen, since any local program can claim to be any client that way.
    def loopback_redirect?(uri)
      host = URI.parse(uri).host.to_s.downcase
      loopback_host?(host) || host.end_with?(".localhost") || host.start_with?("127.")
    rescue URI::InvalidURIError
      false
    end

    def grant_types!(doc, error_code)
      grant_types = doc["grant_types"]
      response_types = doc["response_types"]

      unless grant_types.nil? || (grant_types.is_a?(Array) && grant_types.include?("authorization_code"))
        raise Error.new(error_code, "grant_types must include \"authorization_code\"")
      end
      unless response_types.nil? || (response_types.is_a?(Array) && response_types.include?("code"))
        raise Error.new(error_code, "response_types must include \"code\"")
      end

      GRANT_TYPES
    end

    def client_name(value)
      return nil unless value.is_a?(String)

      value.strip.gsub(/[\p{Cc}\p{Cf}]/, "").first(MAX_CLIENT_NAME_LENGTH).presence
    end
  end
end
