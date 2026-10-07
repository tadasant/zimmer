# frozen_string_literal: true

module OauthServer
  # Deployment configuration for Zimmer's authorization server, read through
  # SecretProviders.chain (the Parameter Store, then Rails credentials, then the
  # process environment) on every request, so a changed value needs no restart.
  # None of these values is a secret, so a store that cannot be reached falls back
  # to the process environment rather than failing the request.
  #
  #   OAUTH_SERVER_ISSUER                     the public origin, e.g. https://zimmer.example.com.
  #                                           Default: https://$APP_HOST, else the request's own origin.
  #   OAUTH_SERVER_ALLOWED_DOMAINS            comma-separated email domains a consenting human must
  #                                           belong to. Default: the web sign-in gate's
  #                                           ZIMMER_WEB_AUTH_ALLOWED_DOMAINS. Neither set means
  #                                           /oauth/authorize issues nothing.
  #   OAUTH_SERVER_ACCESS_TOKEN_TTL_SECONDS   default 3600 (one hour)
  #   OAUTH_SERVER_REFRESH_TOKEN_TTL_SECONDS  default 15552000 (180 days, renewed on every refresh)
  class Config
    ISSUER_KEY = "OAUTH_SERVER_ISSUER"
    ALLOWED_DOMAINS_KEY = "OAUTH_SERVER_ALLOWED_DOMAINS"
    WEB_AUTH_ALLOWED_DOMAINS_KEY = "ZIMMER_WEB_AUTH_ALLOWED_DOMAINS"
    ACCESS_TTL_KEY = "OAUTH_SERVER_ACCESS_TOKEN_TTL_SECONDS"
    REFRESH_TTL_KEY = "OAUTH_SERVER_REFRESH_TOKEN_TTL_SECONDS"

    DEFAULT_ACCESS_TOKEN_TTL = 1.hour
    DEFAULT_REFRESH_TOKEN_TTL = 180.days
    ACCESS_TOKEN_TTL_RANGE = (5.minutes.to_i..1.day.to_i)
    REFRESH_TOKEN_TTL_RANGE = (1.hour.to_i..400.days.to_i)

    MCP_PATH = "/mcp"
    PROTECTED_RESOURCE_METADATA_PATH = "/.well-known/oauth-protected-resource/mcp"

    def self.current(request = nil)
      new(request)
    end

    def initialize(request = nil)
      @request = request
    end

    # The authorization server's issuer identifier: a bare origin, no path.
    def issuer
      @issuer ||= begin
        configured = read(ISSUER_KEY)
        origin = if configured.present?
          configured
        elsif (host = ENV["APP_HOST"]).present?
          "#{local_host?(host) ? 'http' : 'https'}://#{host}"
        else
          @request&.base_url
        end
        origin.to_s.chomp("/")
      end
    end

    # The RFC 8707 resource identifier for `/mcp`, and the audience every access
    # token is bound to. Query strings (`?tool_groups=`) select tools on the one
    # resource; they are not part of it.
    def resource
      "#{issuer}#{MCP_PATH}"
    end

    def protected_resource_metadata_url
      "#{issuer}#{PROTECTED_RESOURCE_METADATA_PATH}"
    end

    # @return [Array<String>] lowercase domains, empty when none is configured
    def allowed_domains
      raw = read(ALLOWED_DOMAINS_KEY) || read(WEB_AUTH_ALLOWED_DOMAINS_KEY)
      raw.to_s.split(",").map { |domain| domain.strip.downcase.delete_prefix("@") }.reject(&:empty?)
    end

    def access_token_ttl
      ttl(ACCESS_TTL_KEY, DEFAULT_ACCESS_TOKEN_TTL, ACCESS_TOKEN_TTL_RANGE)
    end

    def refresh_token_ttl
      ttl(REFRESH_TTL_KEY, DEFAULT_REFRESH_TOKEN_TTL, REFRESH_TOKEN_TTL_RANGE)
    end

    # Does this resource identifier, as a client sent it, name `/mcp`? A query,
    # a fragment and one trailing slash are not part of the comparison: the URL a
    # human pastes into a connector dialog may carry `?tool_groups=`.
    def resource_matches?(candidate)
      uri = URI.parse(candidate.to_s)
      return false unless uri.is_a?(URI::HTTP) && uri.host

      uri.query = nil
      uri.fragment = nil
      uri.to_s.chomp("/") == resource
    rescue URI::InvalidURIError
      false
    end

    # Is `email` inside an allowed domain? False when none is configured.
    def email_allowed?(email)
      local, at, email_domain = email.to_s.strip.downcase.rpartition("@")
      at == "@" && local.present? && allowed_domains.include?(email_domain)
    end

    private

    def read(key)
      SecretProviders.chain.get(key).presence
    rescue StandardError => e
      Rails.logger.warn("[oauth_server] reading #{key} from the secret store failed (#{e.class}); using the process environment")
      ENV[key].presence
    end

    def ttl(key, default, range)
      raw = read(key)
      return default if raw.blank?

      seconds = Integer(raw, exception: false)
      if seconds.nil? || !range.cover?(seconds)
        Rails.logger.warn("[oauth_server] #{key}=#{raw.inspect} is not an integer in #{range}; using #{default.to_i}")
        return default
      end

      seconds.seconds
    end

    def local_host?(host)
      name = host.to_s.split(":").first.to_s.downcase
      name == "localhost" || name.end_with?(".localhost") || name.start_with?("127.") || name == "[::1]"
    end
  end
end
