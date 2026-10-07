# frozen_string_literal: true

module OauthServer
  # Deployment configuration for Zimmer's authorization server, read through
  # SecretProviders.chain (the Parameter Store, then Rails credentials, then the
  # process environment) on every request, so a changed value needs no restart.
  # None of these values is a secret, so a store that cannot be reached falls back
  # to the process environment rather than failing the request — except the
  # allowed domains, which fail closed.
  #
  #   OAUTH_SERVER_ISSUER                     the public origin, e.g. https://zimmer.example.com.
  #                                           Default: AppUrl.base_url (ZIMMER_PROD_BASE_URL in
  #                                           production), the same URL the web sign-in builds its
  #                                           callback from. Never the request's own origin: the
  #                                           Host header is whatever the client or the edge in
  #                                           front of Rails made it.
  #   OAUTH_SERVER_ALLOWED_DOMAINS            comma-separated email domains a consenting human must
  #                                           belong to. Default: the web sign-in's own allowed
  #                                           domains (WebAuth::Configuration). Neither set means
  #                                           /oauth/authorize issues nothing.
  #   OAUTH_SERVER_ACCESS_TOKEN_TTL_SECONDS   default 3600 (one hour)
  #   OAUTH_SERVER_REFRESH_TOKEN_TTL_SECONDS  default 15552000 (180 days, renewed on every refresh)
  class Config
    ISSUER_KEY = "OAUTH_SERVER_ISSUER"
    ALLOWED_DOMAINS_KEY = "OAUTH_SERVER_ALLOWED_DOMAINS"
    ACCESS_TTL_KEY = "OAUTH_SERVER_ACCESS_TOKEN_TTL_SECONDS"
    REFRESH_TTL_KEY = "OAUTH_SERVER_REFRESH_TOKEN_TTL_SECONDS"

    DEFAULT_ACCESS_TOKEN_TTL = 1.hour
    DEFAULT_REFRESH_TOKEN_TTL = 180.days
    ACCESS_TOKEN_TTL_RANGE = (5.minutes.to_i..1.day.to_i)
    REFRESH_TOKEN_TTL_RANGE = (1.hour.to_i..400.days.to_i)

    MCP_PATH = "/mcp"
    PROTECTED_RESOURCE_METADATA_PATH = "/.well-known/oauth-protected-resource/mcp"

    def self.current
      new
    end

    # Raised when no issuer is configured, so nothing can be issued or checked.
    class NotConfigured < OauthServer::Error
      def initialize
        super("temporarily_unavailable",
          "this deployment has not configured its public URL (#{ISSUER_KEY} or #{AppUrl.base_url_key}), so it cannot act as an OAuth server")
      end
    end

    # The authorization server's issuer identifier: a bare origin, no path. Every
    # URL this server publishes — the metadata documents, the `resource`, the
    # audience, `iss` — is built from it, and it comes from configuration only:
    # the request's own scheme and host are what the client or the edge in front
    # of Rails made them, so a forged Host header cannot move the metadata.
    # Development and test fall back to AppUrl's http://localhost:$PORT, so a
    # laptop works out of the box; production and staging with nothing set are
    # unconfigured rather than publishing the placeholder host.
    #
    # @raise [NotConfigured]
    def issuer
      @issuer ||= configured_issuer || raise(NotConfigured)
    end

    def configured?
      issuer.present?
    rescue NotConfigured
      false
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
    #
    # The one value here that is policy rather than plumbing, so a store that
    # cannot be reached does not fall back to the process environment: an empty
    # list (nothing issued) beats a broader one. The web sign-in fallback keeps
    # serving the last list it read, the same list its own wall is enforcing.
    def allowed_domains
      raw = read_strict(ALLOWED_DOMAINS_KEY)
      return raw.split(/[\s,]+/).map { |domain| domain.strip.downcase.delete_prefix("@") }.reject(&:empty?) if raw

      WebAuth::Configuration.current.allowed_domains
    rescue StandardError => e
      Rails.logger.warn("[oauth_server] reading the web sign-in's allowed domains failed (#{e.class}); allowing no domains")
      []
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

    # A bare http(s) origin from OAUTH_SERVER_ISSUER or AppUrl.base_url, or nil.
    def configured_issuer
      origin = read(ISSUER_KEY) || app_base_url
      return nil if origin.blank? || AppUrl.placeholder?(origin)

      uri = URI.parse(origin.strip.chomp("/"))
      if !uri.is_a?(URI::HTTP) || uri.host.blank? || uri.path.present? || uri.query || uri.fragment || uri.userinfo
        Rails.logger.warn("[oauth_server] #{origin.inspect} is not a bare http(s) origin; the OAuth server is unconfigured")
        return nil
      end

      uri.host = uri.host.downcase
      uri.to_s
    rescue URI::InvalidURIError
      Rails.logger.warn("[oauth_server] #{origin.inspect} is not a URL; the OAuth server is unconfigured")
      nil
    end

    def read(key)
      SecretProviders.chain.get(key).presence
    rescue StandardError => e
      Rails.logger.warn("[oauth_server] reading #{key} from the secret store failed (#{e.class}); using the process environment")
      ENV[key].presence
    end

    def app_base_url
      AppUrl.base_url
    rescue StandardError => e
      Rails.logger.warn("[oauth_server] reading the base URL from the secret store failed (#{e.class}); using the process environment")
      ENV[AppUrl.base_url_key].presence || AppUrl.fallback_base_url
    end

    def read_strict(key)
      SecretProviders.chain.get(key).presence
    rescue StandardError => e
      Rails.logger.warn("[oauth_server] reading #{key} from the secret store failed (#{e.class}); allowing no domains")
      nil
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
  end
end
