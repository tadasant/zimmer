# frozen_string_literal: true

require "net/http"
require "openssl"

module ParameterStore
  # Mints a Google access token from a service-account key, via the RFC 7523
  # JWT-bearer grant. No Google SDK: one signed assertion and one form POST.
  #
  # The credential arrives as key JSON in an environment variable. It is a
  # credential *for* the store, so it cannot be kept in the store — and it is
  # deliberately not kept in Zimmer's encrypted credentials either, so that
  # rotating it never requires re-encrypting the file the store is meant to
  # replace.
  class ServiceAccount
    TOKEN_URL = "https://oauth2.googleapis.com/token"
    SCOPE_CLOUD_PLATFORM = "https://www.googleapis.com/auth/cloud-platform"

    # Refresh this far before the token actually expires, so a request in flight
    # when the clock crosses does not 401.
    EXPIRY_SKEW = 60

    attr_reader :client_email

    # Parse key JSON into an account, reporting failures by SHAPE only.
    #
    # Accepts the JSON itself, or BASE64 of it. The base64 form is what a
    # deployed Zimmer actually receives, and the reason is the env-file:
    #
    #   Kamal hands env vars to Docker through an env-file, which is one line
    #   per variable. Kamal escapes a real newline to the two characters `\n`
    #   (Ruby's String#dump) and Docker's --env-file parser unescapes NOTHING,
    #   so those two characters arrive literally. The key JSON that `gcloud iam
    #   service-accounts keys create` writes is PRETTY-PRINTED — structural
    #   newlines between its fields — so it lands in the container with `\n`
    #   between the fields and JSON.parse rejects it outright.
    #
    # Base64 has no byte that the escaping touches, so it survives unchanged.
    # It is the same treatment ZIMMER_OPERATOR_SSH_KEY gets, for the same
    # reason. Raw JSON stays valid input: minified JSON does survive the trip,
    # and a console setting ENV[...] directly has no env-file in the path.
    #
    # The reason strings never quote the input: a malformed key is still a key,
    # and this reason ends up in logs and on the Connectors page.
    #
    # @param raw [String, nil] the service-account key JSON, or base64 of it
    # @param token_url [String, nil] override for the token endpoint (test seam)
    # @return [Array(ServiceAccount, nil), Array(nil, String)] [account, reason]
    def self.parse(raw, token_url: nil)
      # An env var arrives as bytes TAGGED UTF-8, and nothing guarantees they are:
      # a truncated or binary paste is tagged exactly the same way. String#blank?
      # RAISES ArgumentError on such a string, and this runs while the resolution
      # chain is being built, so an unchecked one turns a mangled credential into a
      # crash instead of the degraded state this whole module is built around.
      return [ nil, "is not valid UTF-8" ] if raw.is_a?(String) && !raw.valid_encoding?
      return [ nil, "no key JSON provided" ] if raw.blank?

      parsed = parse_json(raw) || parse_json(decode_base64(raw))
      return [ nil, "is not valid JSON, nor base64 of valid JSON" ] if parsed.nil?

      email = parsed["client_email"]
      key = parsed["private_key"]
      return [ nil, "is missing client_email / private_key" ] if email.blank? || key.blank?

      [ new(client_email: email, private_key: key, token_url: token_url.presence || TOKEN_URL), nil ]
    end

    # @return [Hash, nil] nil for anything that is not a JSON object, so that a
    #   bare `123` or `"a string"` is a shape failure rather than a NoMethodError
    #   two lines later.
    def self.parse_json(raw)
      return nil if raw.nil?

      parsed = JSON.parse(raw)
      parsed.is_a?(Hash) ? parsed : nil
    rescue JSON::ParserError
      nil
    end
    private_class_method :parse_json

    # Whitespace-tolerant, because `base64` without `-w0` wraps at 76 columns and
    # someone will paste that. Strict beyond that: decode64 silently discards
    # anything it does not recognise, which would turn a truncated credential
    # into a confusing JSON error instead of a base64 one.
    #
    # The decoded bytes get the SAME encoding check the raw input gets, and for the
    # same reason: base64 decodes to ASCII-8BIT, JSON.parse will happily read invalid
    # UTF-8 out of it, and the String it hands back then raises ArgumentError from
    # blank? one line later. The outer string being valid base64 says nothing about
    # what is inside it.
    def self.decode_base64(raw)
      decoded = Base64.strict_decode64(raw.gsub(/\s+/, "")).force_encoding(Encoding::UTF_8)
      decoded.valid_encoding? ? decoded : nil
    rescue ArgumentError
      nil
    end
    private_class_method :decode_base64

    def initialize(client_email:, private_key:, token_url: TOKEN_URL, http: nil)
      @client_email = client_email
      @private_key = private_key
      @token_url = token_url
      @http = http
      @mutex = Mutex.new
    end

    # A cached access token, minted on first use and re-minted before expiry.
    #
    # @param scope [String]
    # @return [String]
    # @raise [AuthError]
    def access_token(scope: SCOPE_CLOUD_PLATFORM)
      @mutex.synchronize do
        if @token.nil? || @expires_at.nil? || Time.current + EXPIRY_SKEW >= @expires_at
          @token, @expires_at = mint(scope)
        end
        @token
      end
    end

    private

    def mint(scope)
      response = post_form(@token_url, {
        "grant_type" => "urn:ietf:params:oauth:grant-type:jwt-bearer",
        "assertion" => assertion(scope)
      })

      unless response.is_a?(Net::HTTPSuccess)
        raise AuthError.new("token exchange failed: #{response.code} #{response.message}", response.code.to_i)
      end

      body = JSON.parse(response.body.to_s)
      token = body["access_token"]
      raise AuthError.new("token exchange returned no access_token", 502) if token.blank?

      [ token, Time.current + (body["expires_in"] || 3600).to_i.seconds ]
    rescue JSON::ParserError
      raise AuthError.new("token exchange returned a body that is not JSON", 502)
    end

    def assertion(scope)
      issued_at = Time.current.to_i
      claims = {
        iss: @client_email,
        scope: scope,
        aud: @token_url,
        iat: issued_at,
        exp: issued_at + 3600
      }

      signing_input = "#{b64url(JSON.generate({ alg: "RS256", typ: "JWT" }))}.#{b64url(JSON.generate(claims))}"
      signature = OpenSSL::PKey::RSA.new(pem).sign(OpenSSL::Digest.new("SHA256"), signing_input)

      "#{signing_input}.#{b64url(signature)}"
    end

    # A key that travelled through an env var carries "\n" as two characters.
    def pem
      @private_key.include?('\n') ? @private_key.gsub('\n', "\n") : @private_key
    end

    def b64url(value)
      Base64.urlsafe_encode64(value, padding: false)
    end

    def post_form(url, form)
      return @http.post_form(url, form) if @http

      uri = URI(url)
      request = Net::HTTP::Post.new(uri)
      request.set_form_data(form)

      Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https",
        open_timeout: 5, read_timeout: 10) do |http|
        http.request(request)
      end
    end
  end
end
