# frozen_string_literal: true

require "net/http"

module WebAuth
  # Google's OpenID Connect authorization-code flow, for humans signing in to the
  # web UI. The same shape as strad's console login (src/auth/google.ts).
  #
  # The interesting part is `hd`. Google's `email` claim is NOT proof that an
  # account belongs to a Workspace: a personal account can carry an address on
  # someone else's domain, and `email_verified` can be true for it. The `hd`
  # (hosted domain) claim is emitted only for accounts that actually belong to
  # that Workspace. So the allowlist is checked against `hd`, never against the
  # email's suffix, and the `hd` parameter on the consent URL is only a hint to
  # Google's account chooser.
  #
  # The ID token is not signature-checked against Google's JWKS. It never passes
  # through the browser: Zimmer receives it in the response to its own
  # authenticated POST to Google's token endpoint, over TLS with certificate
  # verification, which OpenID Connect Core 1.0 §3.1.3.7 (step 6) allows in
  # place of the signature check. Issuer, audience and expiry are still checked.
  class GoogleOauth
    AUTH_ENDPOINT = "https://accounts.google.com/o/oauth2/v2/auth"
    TOKEN_ENDPOINT = "https://oauth2.googleapis.com/token"
    ISSUERS = [ "https://accounts.google.com", "accounts.google.com" ].freeze
    TIMEOUT_SECONDS = 10
    # Clock skew tolerated on `exp`.
    LEEWAY = 5.minutes

    # A refusal that is safe to show the person signing in.
    class Rejected < StandardError; end

    # Google, or the network to it, failed. Not the person's fault.
    class ExchangeFailed < StandardError; end

    Identity = Data.define(:sub, :email, :hosted_domain, :name)

    def initialize(configuration)
      @configuration = configuration
    end

    # The consent URL, with PKCE. PKCE costs nothing on a confidential client
    # and closes the authorization-code interception window.
    def authorization_url(state:, code_verifier:)
      query = {
        client_id: @configuration.client_id,
        redirect_uri: @configuration.redirect_uri,
        response_type: "code",
        scope: "openid email profile",
        state: state,
        code_challenge: self.class.code_challenge(code_verifier),
        code_challenge_method: "S256",
        prompt: "select_account"
      }
      # A hint, not a control. Only sent when there is exactly one domain to hint.
      domains = @configuration.allowed_domains
      query[:hd] = domains.first if domains.one?

      "#{AUTH_ENDPOINT}?#{URI.encode_www_form(query)}"
    end

    # Exchange the code and verify who came back.
    #
    # @return [Identity]
    # @raise [Rejected, ExchangeFailed]
    def complete(code:, code_verifier:)
      verify(decode_id_token(fetch_id_token(code: code, code_verifier: code_verifier)))
    end

    # The checks, separated from the network so tests exercise them for real.
    #
    # @param claims [Hash] the ID token's payload
    # @return [Identity]
    # @raise [Rejected]
    def verify(claims, now: Time.current)
      raise Rejected, "Google returned a token for a different issuer." unless ISSUERS.include?(claims["iss"])
      raise Rejected, "Google returned a token for a different application." unless audience_matches?(claims["aud"])
      raise Rejected, "Google's sign-in token has expired. Try again." unless claims["exp"].is_a?(Numeric) && Time.at(claims["exp"]) > now - LEEWAY
      raise Rejected, "Google returned no account id." if claims["sub"].blank?

      hosted_domain = claims["hd"].to_s.downcase
      unless @configuration.domain_allowed?(hosted_domain)
        allowed = @configuration.allowed_domains.join(", ")
        whose = hosted_domain.blank? ? "That is a personal Google account." : "That account belongs to #{hosted_domain}."
        raise Rejected, "#{whose} Zimmer only lets in Google Workspace accounts from #{allowed}."
      end
      unless claims["email"].present? && claims["email_verified"] == true
        raise Rejected, "Google has not verified that account's email address."
      end

      Identity.new(sub: claims["sub"].to_s, email: claims["email"].to_s.downcase, hosted_domain: hosted_domain, name: claims["name"].presence)
    end

    def self.code_challenge(verifier)
      Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
    end

    private

    def audience_matches?(aud)
      Array(aud).include?(@configuration.client_id)
    end

    def fetch_id_token(code:, code_verifier:)
      uri = URI(TOKEN_ENDPOINT)
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: TIMEOUT_SECONDS, read_timeout: TIMEOUT_SECONDS) do |http|
        request = Net::HTTP::Post.new(uri)
        request.set_form_data(
          code: code,
          client_id: @configuration.client_id,
          client_secret: @configuration.client_secret,
          redirect_uri: @configuration.redirect_uri,
          grant_type: "authorization_code",
          code_verifier: code_verifier
        )
        http.request(request)
      end

      unless response.is_a?(Net::HTTPSuccess)
        # Google's error body names the problem (invalid_grant, redirect_uri_mismatch, …)
        # and carries no secret.
        raise ExchangeFailed, "Google's token endpoint answered #{response.code}: #{response.body.to_s.truncate(300)}"
      end

      JSON.parse(response.body).fetch("id_token") { raise ExchangeFailed, "Google returned no id_token" }
    rescue JSON::ParserError, SocketError, SystemCallError, Net::OpenTimeout, Net::ReadTimeout, OpenSSL::SSL::SSLError, IOError => e
      raise ExchangeFailed, "could not reach Google's token endpoint: #{e.class}: #{e.message}"
    end

    def decode_id_token(id_token)
      payload = id_token.to_s.split(".")[1]
      raise ExchangeFailed, "Google returned a malformed id_token" if payload.blank?

      JSON.parse(Base64.urlsafe_decode64(payload + ("=" * (-payload.length % 4))))
    rescue ArgumentError, JSON::ParserError
      raise ExchangeFailed, "Google returned a malformed id_token"
    end
  end
end
