# frozen_string_literal: true

require "net/http"

module AppStoreConnect
  # A read-only App Store Connect API client: signs a short-lived ES256 JWT
  # with an API key and makes GET requests. Only what TestflightFeedbackPoller
  # needs.
  #
  # The key is three values, resolved through SecretProviders (Parameter Store,
  # then Rails credentials, then ENV):
  #
  #   TESTFLIGHT_ASC_ISSUER_ID  the issuer id (App Store Connect → Users and
  #                             Access → Integrations → App Store Connect API)
  #   TESTFLIGHT_ASC_KEY_ID     the key id
  #   TESTFLIGHT_ASC_KEY_P8     the .p8 private key: the PEM text, the PEM with
  #                             its newlines escaped as `\n`, or base64 of it
  #
  # Deliberately not the `APP_STORE_CONNECT_API_*` names the TestFlight upload
  # workflow uses: a store-resolved variable can reach a session's environment,
  # and `ios/bin/testflight` reads those names, so a session that happened to
  # inherit them would be holding an upload key.
  #
  # Nothing here logs the key, the token, or a response body.
  class Client
    API = "https://api.appstoreconnect.apple.com"
    ISSUER_ID_VARIABLE = "TESTFLIGHT_ASC_ISSUER_ID"
    KEY_ID_VARIABLE = "TESTFLIGHT_ASC_KEY_ID"
    PRIVATE_KEY_VARIABLE = "TESTFLIGHT_ASC_KEY_P8"
    VARIABLES = [ ISSUER_ID_VARIABLE, KEY_ID_VARIABLE, PRIVATE_KEY_VARIABLE ].freeze

    # Apple refuses a token that lives longer than 20 minutes.
    TOKEN_LIFETIME = 15.minutes
    OPEN_TIMEOUT_SECONDS = 10
    READ_TIMEOUT_SECONDS = 60

    class Error < StandardError
      attr_reader :status

      def initialize(message, status: nil)
        super(message)
        @status = status
      end
    end

    class NotFound < Error; end

    Credentials = Data.define(:issuer_id, :key_id, :private_key)

    # The three values, or nil when any is missing. A store that cannot be
    # reached raises: "could not ask" is not "not configured".
    def self.credentials(chain: SecretProviders.chain)
      values = VARIABLES.map { |name| chain.get(name).to_s.strip.presence }
      return nil if values.any?(&:nil?)

      Credentials.new(issuer_id: values[0], key_id: values[1], private_key: normalize_pem(values[2]))
    end

    # A multi-line PEM does not survive every secret console intact, so accept
    # the forms it is likely to arrive in.
    def self.normalize_pem(value)
      text = value.to_s.strip
      text = text.gsub("\\n", "\n") if text.include?("\\n")
      unless text.include?("BEGIN")
        decoded = Base64.decode64(text)
        text = decoded if decoded.include?("BEGIN")
      end
      text
    end

    def initialize(credentials:, base_url: API, transport: nil, clock: -> { Time.now })
      @credentials = credentials
      @base_url = base_url.chomp("/")
      @transport = transport || method(:http_get)
      @clock = clock
    end

    # @param path [String] e.g. "/v1/apps" — or a full `links.next` URL
    # @return [Hash] the parsed JSON document
    def get(path, params = {})
      uri = path.start_with?("http") ? URI(path) : URI("#{@base_url}#{path}")
      uri.query = URI.encode_www_form(params) if params.any?
      status, body = @transport.call(uri, { "Authorization" => "Bearer #{token}", "Accept" => "application/json" })

      raise NotFound.new("App Store Connect: #{uri.path} not found", status: status) if status == 404
      raise Error.new("App Store Connect answered #{status} for #{uri.path}#{error_detail(body)}", status: status) unless (200..299).cover?(status)

      JSON.parse(body)
    end

    # The signed bearer token. Re-minted per request: it is a local signature,
    # and a long poll would otherwise outlive a cached one.
    def token
      now = @clock.call.to_i
      JWT.encode(
        { iss: @credentials.issuer_id, iat: now, exp: now + TOKEN_LIFETIME.to_i, aud: "appstoreconnect-v1" },
        OpenSSL::PKey::EC.new(@credentials.private_key),
        "ES256",
        { kid: @credentials.key_id, typ: "JWT" }
      )
    end

    private

    # Apple's error documents name the problem in `errors[].code`/`title`, never
    # anything tester-supplied, so they are safe to put in an exception message.
    def error_detail(body)
      errors = JSON.parse(body.to_s)["errors"]
      return "" unless errors.is_a?(Array) && errors.any?

      ": " + errors.first(3).map { |e| [ e["code"], e["title"] ].compact.join(" ") }.join("; ")
    rescue JSON::ParserError
      ""
    end

    def http_get(uri, headers)
      request = Net::HTTP::Get.new(uri)
      headers.each { |name, value| request[name] = value }
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
        open_timeout: OPEN_TIMEOUT_SECONDS, read_timeout: READ_TIMEOUT_SECONDS) do |http|
        http.request(request)
      end
      [ response.code.to_i, response.body ]
    end
  end
end
